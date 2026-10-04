import SwiftUI
import AVFoundation

@main struct CowboyRecApp: App {
  var body: some Scene { WindowGroup { RecorderView() } }
}
struct RecorderView: View {
  @StateObject private var camera = NativeCamera()
  @State private var portal: CowboyPortal?
  @State private var portalControl = CowboyPortalControl()
  @State private var captureWarning = false
  @State private var settings = false
  @State private var strength = 3
  @State private var zoom: Double = 1
  @State private var zoomEditing = false
  @Environment(\.scenePhase) private var phase
  private var cloud: CowboyCloud { .shared }
  private let gold = Color(red: 0.91, green: 0.65, blue: 0.24)
  var body: some View {
    GeometryReader { geometry in
    ZStack {
      Color.black.ignoresSafeArea()
      CameraPreview(camera: camera).ignoresSafeArea()
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading,spacing: 3) {
            Text("COWBOY REC · 0.3.1").font(.headline).tracking(2)
            Text("4K · 60 FPS · \(NativeCamera.label(camera.activeMode))").font(.caption2)
          }
          Spacer()
          Button { settings=true } label: { Image(systemName: "slider.horizontal.3").font(.title3).padding(12) }
        }.padding(.horizontal,18).padding(.vertical,8).background(.black.opacity(0.65))
        if !camera.ready { Text(camera.status).font(.caption).padding(12).background(.black.opacity(0.7)) }
        Spacer()
        VStack(spacing: 12) {
          if cloud.email == nil {
            Button("Entrar na conta Cowboy para gravar") { open(.account) }.font(.subheadline).padding(10)
          } else { Text(cloud.status).font(.caption2).lineLimit(2) }
          HStack(spacing: 8) {
            ForEach(camera.zoomPresets,id: \.self) { value in
              Button { camera.selectZoom(value) } label: {
                Text(String(format: "%g×",value)).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical,9)
              }.background(abs(camera.zoom-value)<0.12 ? gold.opacity(0.35) : Color.black.opacity(0.4),in: Capsule())
            }
          }.disabled(!camera.ready)
          HStack {
            Text(String(format: "%.1f×",camera.zoom)).font(.caption).monospacedDigit().frame(width: 42)
            Slider(value: $zoom,in: camera.minimumZoom...max(camera.minimumZoom+0.01,camera.maximumZoom),onEditingChanged: { editing in
              zoomEditing=editing
              if !editing { camera.setZoom(zoom) }
            }).onChange(of: zoom) { _,value in if zoomEditing { camera.setZoom(value) } }
              .onChange(of: camera.zoom) { _,value in if !zoomEditing { zoom=max(camera.minimumZoom,min(camera.maximumZoom,value)) } }
          }.disabled(!camera.ready)
          HStack {
            Button { open(.library) } label: { VStack { Image(systemName: "photo.stack").font(.title2); Text("Biblioteca").font(.caption2) }.frame(maxWidth: .infinity) }.disabled(camera.recording || camera.finishing)
            Button(action: record) {
              ZStack {
                Circle().stroke(.white,lineWidth: 3).frame(width: 76,height: 76)
                if camera.recording { RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30,height: 30) }
                else { Circle().fill(.red).frame(width: 62,height: 62) }
                if camera.finishing { ProgressView().tint(.white) }
              }
            }.disabled(!camera.ready || camera.finishing).accessibilityLabel(camera.recording ? "Parar gravação" : "Gravar")
            Button { open(.rec) } label: { VStack { Image(systemName: "square.grid.2x2").font(.title2); Text("Rec completo").font(.caption2) }.frame(maxWidth: .infinity) }.disabled(camera.recording || camera.finishing)
          }
          if camera.recording { Text("GRAVANDO").font(.caption.weight(.bold)).foregroundStyle(.red) }
        }.padding(20).frame(maxWidth:geometry.size.width > geometry.size.height ? 360 : .infinity).background(LinearGradient(colors: [.clear,.black.opacity(0.9),.black],startPoint: .top,endPoint: .bottom)).frame(maxWidth:.infinity,alignment:.trailing)
      }
    }
    }.tint(gold).preferredColorScheme(.dark)
      .fullScreenCover(item: $portal,onDismiss: {
        Task { await cloud.refresh(); if let owner=cloud.email { camera.recoverSaved(owner: owner) }; camera.start() }
      }) { destination in
        VStack(spacing:0) {
          HStack {
            Text("Cowboy Rec · app nativo 0.3.1").font(.caption.weight(.bold))
            Spacer()
            Button("Câmera 4K/60") {
              Task { if await portalControl.canReturnToCamera() { portal=nil } else { captureWarning=true } }
            }.buttonStyle(.borderedProminent)
          }.padding(12).background(Color.black)
          CowboyAccountView(destination:destination,control:portalControl)
        }
        .alert("Gravação em andamento",isPresented:$captureWarning) { Button("OK",role:.cancel) {} } message: { Text("Pare a gravação antes de voltar à câmera nativa.") }
        .preferredColorScheme(.dark)
      }
      .sheet(isPresented: $settings) {
        NavigationStack {
          Form {
            Section("Câmera nativa") {
              Picker("Estabilização",selection: $strength) {
                Text("Desligada").tag(0); Text("Standard").tag(1); Text("Cinematic").tag(2); Text("Forte").tag(3)
              }.disabled(camera.recording || camera.finishing).onChange(of: strength) { _,value in camera.setStabilization(value) }
              Toggle("Travar luz e cor",isOn:Binding(get:{camera.colorLocked},set:{camera.lockColor($0)})).disabled(!camera.ready)
              Text(camera.status).font(.caption)
            }
            Section("Conta e sincronização") {
              Text(cloud.email ?? "Você ainda não entrou na conta")
              Text(cloud.status).font(.caption)
              Button("Entrar / gerenciar conta") { settings=false; DispatchQueue.main.asyncAfter(deadline: .now()+0.4) { open(.account) } }.disabled(camera.recording || camera.finishing)
              Button("Retomar envios") { Task { await cloud.refresh() } }
              Text("A captura nativa é salva no iPhone e enviada à biblioteca da VPS ao parar. Limite atual: 256 MB por clipe.").font(.caption)
              if let file=camera.recoverableFile { ShareLink("Exportar captura preservada",item: file) }
            }
          }.navigationTitle("Configurações").toolbar { Button("OK") { settings=false } }
        }.presentationDetents([.medium,.large])
      }
      .task {
        camera.onSaved = { file,owner in
          do {
            try cloud.enqueue(file,owner: owner)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("owner"))
            try? FileManager.default.removeItem(at: file.appendingPathExtension("capture"))
            try? FileManager.default.removeItem(at: file)
            camera.recoverableFile=nil
          } catch { camera.recoverableFile=file; camera.status="Vídeo preservado: \(error.localizedDescription)" }
        }
        await cloud.refresh()
        if let owner=cloud.email { camera.recoverSaved(owner: owner); camera.start() } else { open(.account) }
      }
      .onChange(of: phase) { _,value in
        if value != .active { camera.close() }
        else if portal == nil { camera.start(); Task { await cloud.refresh() } }
      }
  }
  private func open(_ destination: CowboyPortal) { camera.close(); portal=destination }
  private func record() {
    if camera.recording { camera.stopRecording(); return }
    guard let owner=cloud.email else { open(.account); return }
    do { try cloud.checkCapacity(); camera.record(owner: owner) }
    catch { camera.status=error.localizedDescription; settings=true }
  }
}
