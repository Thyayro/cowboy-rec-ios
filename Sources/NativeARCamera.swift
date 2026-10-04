import ARKit
import AVFoundation
import SceneKit
import SwiftUI

final class NativeARCamera: NSObject, ObservableObject, ARSessionDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  let session=ARSession()
  private let queue=DispatchQueue(label:"cowboy.arkit.capture",qos:.userInitiated)
  private let audioSession=AVCaptureSession()
  private let audioOutput=AVCaptureAudioDataOutput()
  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var started: Double?
  private var file: URL?
  private var poseFile: FileHandle?
  private var owner: String?
  private var samples=0
  private var dropped=0
  private var lastUI:Double=0
  private var width=0,height=0,fps=0
  @Published var ready=false
  @Published var recording=false
  @Published var finishing=false
  @Published var formatLabel="ARKit aguardando"
  @Published var tracking="Aponte para uma área com textura e mova devagar"
  @Published var status="Chão apenas na prévia; vídeo e poses enviados ao parar"
  @Published var floorSelected=false
  @Published var planeCount=0
  var onSaved: ((URL,String?) -> Void)?
  private func publish(_ action:@escaping @Sendable () -> Void) { DispatchQueue.main.async(execute:action) }
  func start() {
    Task {
      let camera=await AVCaptureDevice.requestAccess(for:.video),microphone=await AVCaptureDevice.requestAccess(for:.audio)
      guard camera && microphone,ARWorldTrackingConfiguration.isSupported else { publish { self.status="Libere câmera/microfone; ARKit precisa de um aparelho compatível" };return }
      queue.async {
        do {
          if self.audioSession.inputs.isEmpty {
            guard let microphone=AVCaptureDevice.default(for:.audio) else { throw self.error("Microfone indisponível") }
            let input=try AVCaptureDeviceInput(device:microphone)
            guard self.audioSession.canAddInput(input),self.audioSession.canAddOutput(self.audioOutput) else { throw self.error("Áudio AR indisponível") }
            self.audioSession.addInput(input);self.audioSession.addOutput(self.audioOutput)
            self.audioOutput.setSampleBufferDelegate(self,queue:self.queue)
          }
          let options=ARWorldTrackingConfiguration.supportedVideoFormats
          guard let format=options.filter({$0.framesPerSecond>=60}).max(by:{$0.imageResolution.width*$0.imageResolution.height<$1.imageResolution.width*$1.imageResolution.height}) ?? options.max(by:{$0.imageResolution.width*$0.imageResolution.height<$1.imageResolution.width*$1.imageResolution.height}) else { throw self.error("Sem formato AR disponível") }
          let config=ARWorldTrackingConfiguration();config.videoFormat=format;config.planeDetection=[.horizontal];config.isVideoHDREnabled=false
          self.fps=format.framesPerSecond;self.width=Int(format.imageResolution.width);self.height=Int(format.imageResolution.height)
          self.session.delegate=self;self.session.delegateQueue=self.queue;self.session.run(config,options:[.resetTracking,.removeExistingAnchors])
          self.publish { self.formatLabel="AR \(self.width)×\(self.height) · \(self.fps) fps";self.floorSelected=false }
        } catch { self.publish { self.status=error.localizedDescription } }
      }
    }
  }
  private func error(_ message:String)->NSError { NSError(domain:"CowboyAR",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
  func setFloor(_ transform:simd_float4x4) {
    queue.async {
      guard self.writer == nil else { return }
      self.session.setWorldOrigin(relativeTransform:transform)
      self.publish { self.floorSelected=true;self.status="Origem 3D fixada no chão tocado" }
    }
  }
  func record(owner:String) {
    queue.async {
      guard self.writer == nil,let frame=self.session.currentFrame,case .normal=frame.camera.trackingState else { self.publish { self.status="Espere o rastreamento ficar normal antes de gravar" };return }
      do {
        let dir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CowboyCaptures")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let file=dir.appendingPathComponent(UUID().uuidString+".mov")
        let writer=try AVAssetWriter(outputURL:file,fileType:.mov)
        let width=CVPixelBufferGetWidth(frame.capturedImage),height=CVPixelBufferGetHeight(frame.capturedImage)
        let settings:[String:Any]=[AVVideoCodecKey:AVVideoCodecType.hevc,AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:min(50000000,max(8000000,width*height*self.fps/8))]]
        guard writer.canApply(outputSettings:settings,forMediaType:.video) else { throw self.error("Formato AR não pode ser codificado em HEVC") }
        let video=AVAssetWriterInput(mediaType:.video,outputSettings:settings);video.expectsMediaDataInRealTime=true
        let audio=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:1,AVEncoderBitRateKey:128000]);audio.expectsMediaDataInRealTime=true
        guard writer.canAdd(video),writer.canAdd(audio) else { throw self.error("Saída AR indisponível") }
        writer.add(video);writer.add(audio)
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:video,sourcePixelBufferAttributes:nil)
        guard writer.startWriting() else { throw writer.error ?? self.error("Não foi possível iniciar AR") }
        writer.startSession(atSourceTime:.zero)
        try JSONEncoder().encode(owner).write(to:file.appendingPathExtension("owner"),options:.atomic)
        let metadata=NativeCaptureMetadata(width:width,height:height,frameRate:Double(self.fps),hdr:false,codec:AVVideoCodecType.hevc.rawValue,lens:"ARKit traseira",stabilization:"Desligada para preservar poses",colorProfile:"rec709",convertRec709:false,captureMode:"arkit")
        try JSONEncoder().encode(metadata).write(to:file.appendingPathExtension("capture"),options:.atomic)
        let poseURL=file.appendingPathExtension("ar")
        FileManager.default.createFile(atPath:poseURL.path,contents:nil)
        let handle=try FileHandle(forWritingTo:poseURL)
        let header:[String:Any]=["schema":"cowboy-arkit/v1","width":width,"height":height,"fps":self.fps,"coordinate_system":"ARKit right-handed, meters; transform column-major","floor_origin_selected":self.floorSelected]
        var data=try JSONSerialization.data(withJSONObject:header);data.removeLast();data.append(contentsOf:",\"frames\":[".utf8);try handle.write(contentsOf:data)
        self.writer=writer;self.videoInput=video;self.audioInput=audio;self.adaptor=adaptor;self.started=nil;self.file=file;self.owner=owner;self.poseFile=handle;self.samples=0;self.dropped=0
        if !self.audioSession.isRunning { self.audioSession.startRunning() }
        self.publish { self.recording=true;self.status="Gravando vídeo e poses 3D sincronizados" }
      } catch { self.publish { self.status=error.localizedDescription } }
    }
  }
  func session(_ session:ARSession,didUpdate frame:ARFrame) {
    let quality:String
    switch frame.camera.trackingState { case .normal:quality="normal";case .notAvailable:quality="indisponível";case .limited(let reason):quality="limitado: \(reason)" }
    if writer == nil {
      if frame.timestamp-lastUI>=0.25 { lastUI=frame.timestamp;publish { self.tracking=quality;self.ready=quality=="normal";self.planeCount=frame.anchors.filter{$0 is ARPlaneAnchor}.count } }
      return
    }
    guard let writer,writer.status == .writing,let input=videoInput,let adaptor,input.isReadyForMoreMediaData else { dropped+=1;return }
    if started == nil { started=frame.timestamp }
    let t=frame.timestamp-started!
    guard adaptor.append(frame.capturedImage,withPresentationTime:CMTime(seconds:t,preferredTimescale:600000)) else { finish();return }
    let transform=frame.camera.transform,calibration=frame.camera.intrinsics
    let matrix=(0..<4).flatMap { column in (0..<4).map { row in Double(transform[column][row]) } }
    let intrinsics=(0..<3).flatMap { column in (0..<3).map { row in Double(calibration[column][row]) } }
    let sample:[String:Any]=["t":t,"transform":matrix,"intrinsics":intrinsics,"tracking":quality]
    do {
      var data=try JSONSerialization.data(withJSONObject:sample)
      if samples>0 { data.insert(44,at:0) };try poseFile?.write(contentsOf:data);samples+=1
      if samples%60==0 {
        publish { self.tracking=quality;self.status="AR: \(self.samples) quadros · \(self.dropped) descartados" }
        let size=(try? file?.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
        if size>=256*1024*1024 || samples>=25000 { finish() }
      }
    } catch { publish { self.status="Falha ao salvar poses: \(error.localizedDescription)" };finish() }
  }
  func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
    guard let started,writer?.status == .writing,let input=audioInput,input.isReadyForMoreMediaData else { return }
    var timing=CMSampleTimingInfo();guard CMSampleBufferGetSampleTimingInfo(sampleBuffer,at:0,timingInfoOut:&timing)==noErr else { return }
    timing.presentationTimeStamp=CMTimeSubtract(timing.presentationTimeStamp,CMTime(seconds:started,preferredTimescale:600000));timing.decodeTimeStamp = .invalid
    guard timing.presentationTimeStamp.seconds>=0 else { return }
    var copy:CMSampleBuffer?
    if CMSampleBufferCreateCopyWithNewTiming(allocator:kCFAllocatorDefault,sampleBuffer:sampleBuffer,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleBufferOut:&copy)==noErr,let copy { input.append(copy) }
  }
  func stop() { queue.async { self.finish() } }
  private func finish() {
    guard let writer,let file else { return }
    let owner=self.owner
    self.videoInput?.markAsFinished();self.audioInput?.markAsFinished()
    try? poseFile?.write(contentsOf:Data("]}".utf8));try? poseFile?.close();poseFile=nil
    self.writer=nil;self.adaptor=nil;self.started=nil
    if audioSession.isRunning { audioSession.stopRunning() }
    publish { self.recording=false;self.finishing=true }
    writer.finishWriting { self.publish {
      self.finishing=false
      if writer.status == .completed { self.onSaved?(file,owner);self.status="Captura AR salva; envio para VPS" }
      else { self.status="Captura interrompida preservada: \(writer.error?.localizedDescription ?? "erro")" }
    } }
  }
  func close() { queue.async { self.finish();self.session.pause();if self.audioSession.isRunning { self.audioSession.stopRunning() };self.publish { self.ready=false } } }
  func session(_ session:ARSession,didFailWithError error:Error) { queue.async { self.finish();self.publish { self.status=error.localizedDescription;self.ready=false } } }
  func sessionWasInterrupted(_ session:ARSession) { queue.async { self.finish();self.publish { self.ready=false;self.status="AR interrompido; capture novamente ao voltar" } } }
}

struct NativeARPreview:UIViewRepresentable {
  let camera:NativeARCamera
  func makeCoordinator()->Coordinator { Coordinator(camera:camera) }
  func makeUIView(context:Context)->ARSCNView {
    let view=ARSCNView();view.session=camera.session;view.delegate=context.coordinator;view.automaticallyUpdatesLighting=false
    view.preferredFramesPerSecond=60
    view.addGestureRecognizer(UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tapped(_:))))
    return view
  }
  func updateUIView(_ view:ARSCNView,context:Context) {}
  final class Coordinator:NSObject,ARSCNViewDelegate {
    let camera:NativeARCamera
    let grid:UIImage
    init(camera:NativeARCamera) {
      self.camera=camera
      grid=UIGraphicsImageRenderer(size:CGSize(width:256,height:256)).image { context in
        context.cgContext.setStrokeColor(UIColor.systemYellow.withAlphaComponent(0.8).cgColor);context.cgContext.setLineWidth(2)
        for n in stride(from:0,through:256,by:32) { context.cgContext.move(to:CGPoint(x:CGFloat(n),y:0));context.cgContext.addLine(to:CGPoint(x:CGFloat(n),y:256));context.cgContext.move(to:CGPoint(x:0,y:CGFloat(n)));context.cgContext.addLine(to:CGPoint(x:256,y:CGFloat(n))) };context.cgContext.strokePath()
      }
    }
    @objc func tapped(_ gesture:UITapGestureRecognizer) {
      guard !camera.recording,!camera.finishing,let view=gesture.view as? ARSCNView,let query=view.raycastQuery(from:gesture.location(in:view),allowing:.existingPlaneGeometry,alignment:.horizontal),let result=view.session.raycast(query).first else { return }
      camera.setFloor(result.worldTransform)
    }
    func renderer(_ renderer:SCNSceneRenderer,didAdd node:SCNNode,for anchor:ARAnchor) {
      guard let plane=anchor as? ARPlaneAnchor else { return }
      let geometry=SCNPlane(width:CGFloat(max(0.1,plane.extent.x)),height:CGFloat(max(0.1,plane.extent.z)))
      let material=SCNMaterial();material.diffuse.contents=grid;material.isDoubleSided=true;material.lightingModel = .constant;material.diffuse.wrapS = .repeat;material.diffuse.wrapT = .repeat;geometry.materials=[material]
      let gridNode=SCNNode(geometry:geometry);gridNode.name="floor";gridNode.eulerAngles.x = -.pi/2;gridNode.simdPosition=plane.center;node.addChildNode(gridNode)
    }
    func renderer(_ renderer:SCNSceneRenderer,didUpdate node:SCNNode,for anchor:ARAnchor) {
      guard let plane=anchor as? ARPlaneAnchor,let gridNode=node.childNode(withName:"floor",recursively:false),let geometry=gridNode.geometry as? SCNPlane else { return }
      geometry.width=CGFloat(max(0.1,plane.extent.x));geometry.height=CGFloat(max(0.1,plane.extent.z));gridNode.simdPosition=plane.center
    }
  }
}
struct NativeARRecorderView:View {
  @StateObject private var camera=NativeARCamera()
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var phase
  private var cloud:CowboyCloud { .shared }
  var body:some View {
    ZStack {
      NativeARPreview(camera:camera).ignoresSafeArea()
      VStack {
        HStack { Text(camera.formatLabel).font(.headline);Spacer();Button("Câmera cinema") { camera.close();dismiss() }.disabled(camera.recording || camera.finishing) }.padding().background(.black.opacity(0.7))
        Spacer()
        VStack(spacing:12) {
          Text("\(camera.tracking) · \(camera.planeCount) planos").font(.caption)
          Text(camera.floorSelected ? "Origem fixada no chão" : "Mova devagar e toque no chão detectado para fixar a origem").font(.caption)
          Button(camera.recording ? "Parar e enviar AR" : "Gravar vídeo + poses 3D") {
            if camera.recording { camera.stop() }
            else if let owner=cloud.email { do { try cloud.checkCapacity();camera.record(owner:owner) } catch { camera.status=error.localizedDescription } }
          }.buttonStyle(.borderedProminent).disabled((!camera.ready && !camera.recording) || camera.finishing || cloud.email == nil)
          Text(camera.status).font(.caption)
          Text(cloud.status).font(.caption2)
          Text("Vídeo AR no quadro original horizontal, sem grade · áudio + poses · envio ao parar").font(.caption2)
        }.padding().background(.black.opacity(0.8))
      }
    }.preferredColorScheme(.dark).tint(.yellow).task {
      camera.onSaved={ file,owner in
        do {
          try cloud.enqueue(file,owner:owner)
          for suffix in ["owner","capture","ar"] { try? FileManager.default.removeItem(at:file.appendingPathExtension(suffix)) }
          try? FileManager.default.removeItem(at:file)
        } catch { camera.status="Vídeo AR preservado: \(error.localizedDescription)" }
      };camera.start()
    }.onDisappear { camera.close() }.onChange(of:phase) { _,phase in if phase != .active { camera.close() } else { camera.start() } }
  }
}
