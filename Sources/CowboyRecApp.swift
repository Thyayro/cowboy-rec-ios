import SwiftUI
import AVFoundation

@main struct CowboyRecApp: App {
  var body: some Scene { WindowGroup { RecorderView() } }
}
struct RecorderView: View {
  @StateObject private var camera = NativeCamera()
  @State private var account = false
  @State private var strength = 3
  @State private var zoom: Double = 1
  @State private var locked = false
  @Environment(\.scenePhase) private var phase
  private var cloud: CowboyCloud { .shared }
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Cowboy Rec").font(.headline)
        Spacer()
        Button("Conta / biblioteca") { account = true }.disabled(camera.recording || camera.finishing)
      }
      CameraPreview(camera: camera).background(.black).aspectRatio(9.0 / 16.0, contentMode: .fit)
      Text(camera.status).font(.caption)
      HStack {
        Text(String(format: "%.1f×", camera.zoom)).monospacedDigit()
        Slider(value: $zoom, in: camera.minimumZoom...max(camera.minimumZoom + 0.01, camera.maximumZoom))
          .onChange(of: zoom) { _, value in camera.setZoom(value) }
      }.disabled(!camera.ready)
      HStack {
        ForEach([0.5, 1, 2, 5, 10], id: \.self) { value in
          Button(String(format: "%g×", value)) { zoom = min(camera.maximumZoom, max(camera.minimumZoom, value)) }
        }
      }.disabled(!camera.ready)
      Picker("Estabilização", selection: $strength) {
        Text("Desligada").tag(0); Text("Standard").tag(1); Text("Cinematic").tag(2); Text("Forte").tag(3)
      }.pickerStyle(.menu).disabled(camera.recording || camera.finishing)
        .onChange(of: strength) { _, value in camera.setStabilization(value) }
      Toggle("Travar luz e cor", isOn: $locked).onChange(of: locked) { _, value in camera.lockColor(value) }
        .disabled(!camera.ready)
      HStack {
        Button(camera.recording ? "Parar e enviar" : "Gravar") {
          if camera.recording { camera.stopRecording() }
          else if let owner = cloud.email {
            do { try cloud.checkCapacity(); camera.record(owner: owner) }
            catch { camera.status = error.localizedDescription }
          }
        }.buttonStyle(.borderedProminent).disabled(!camera.ready || camera.finishing || cloud.email == nil)
        Button("Retomar envios") { Task { await cloud.refresh() } }
      }
      Text(cloud.status).font(.caption)
      Text("Envio ao parar · limite de 256 MB por clipe").font(.caption2)
      if let file = camera.recoverableFile { ShareLink("Salvar vídeo que não entrou na fila", item: file) }
    }.padding().preferredColorScheme(.dark)
      .sheet(isPresented: $account, onDismiss: { Task { await cloud.refresh(); if let owner = cloud.email { camera.recoverSaved(owner: owner) }; camera.start() } }) {
        NavigationStack { CowboyAccountView().toolbar { Button("Voltar à câmera") { account = false } } }
      }
      .task {
        camera.onSaved = { file, owner in
          do {
            try cloud.enqueue(file, owner: owner)
            // The queue now owns a durable copy; remove only the redundant capture.
            try? FileManager.default.removeItem(at: file.appendingPathExtension("owner"))
            try? FileManager.default.removeItem(at: file)
            camera.recoverableFile = nil
          }
          catch { camera.recoverableFile = file; camera.status = "Vídeo mantido no aparelho: \(error.localizedDescription)" }
        }
        await cloud.refresh(); if let owner = cloud.email { camera.recoverSaved(owner: owner) }; camera.start()
      }
      .onChange(of: phase) { _, value in
        if value != .active { camera.close() }
        else if !account { camera.start(); Task { await cloud.refresh() } }
      }
  }
}
