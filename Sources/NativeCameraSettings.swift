import SwiftUI
import AVFoundation

struct NativeCameraSettings: View {
  @ObservedObject var camera: NativeCamera
  let configuringDisabled: Bool
  var body: some View {
    Group {
      Section("Estabilização") {
        Picker("Modo", selection: Binding(get: { camera.stabilizationChoice }, set: { camera.setStabilization($0) })) {
          Text("Desligada").tag(0); Text("Standard").tag(1); Text("Cinematic").tag(2); Text("Cinematic Extended").tag(3); Text("Extrema").tag(4)
        }.pickerStyle(.segmented).disabled(configuringDisabled)
        Text("Ativa agora: \(NativeCamera.label(camera.activeMode))").font(.caption)
        Text("Extrema = Cinematic Extended Enhanced do iOS 18 (o modo mais forte da Apple: segura caminhada e corrida, recorta mais as bordas e atrasa um pouco a prévia). A prévia mostra o quadro já estabilizado — o mesmo que vai pro arquivo. Se o formato não tiver o modo pedido, cai pro mais forte que ele aceita, sem baixar resolução nem fps.").font(.caption2)
      }
      Section("Lente e formato reais") {
        Picker("Câmera", selection: Binding(get: { camera.lensID }, set: { camera.selectLens($0) })) {
          ForEach(camera.lenses) { lens in Text(lens.name).tag(lens.id) }
        }.disabled(configuringDisabled || camera.lenses.isEmpty)
        Picker("Resolução / FPS", selection: Binding(get: { camera.profileID }, set: { camera.selectProfile($0) })) {
          ForEach(camera.profiles) { profile in Text(profile.label).tag(profile.id) }
        }.disabled(configuringDisabled || camera.profiles.isEmpty)
        Text("Padrão: traseira automática (0,5× · 1× · 2× · 5× com zoom contínuo, trocando de lente sozinha como a câmera do iPhone). \"Só a principal\" trava numa lente.").font(.caption2)
      }
      Section("Cor") {
        Toggle("Apple Log", isOn: Binding(get: { camera.logEnabled }, set: { camera.setLog($0) })).disabled(configuringDisabled || !camera.logAvailable)
        if !camera.logAvailable { Text("Apple Log não aparece nesta lente/formato (\(camera.formatLabel)). Só iPhone Pro grava Log.").font(.caption2) }
        Toggle("HDR (HLG)", isOn: Binding(get: { camera.hdrEnabled }, set: { camera.setHDR($0) })).disabled(configuringDisabled || !camera.hdrAvailable || camera.logEnabled)
        Toggle("Prévia em Rec.709 (LUT do Log)", isOn: Binding(get: { !camera.rawLog }, set: { camera.setRawLog(!$0) })).disabled(!(camera.logEnabled || camera.hdrEnabled))
        Toggle("Arquivo final em Rec.709 + look", isOn: $camera.bake709).disabled(configuringDisabled)
        Text(camera.bake709 ? "Ligado: cada quadro do Log real (10 bits) é convertido no iPhone pela curva oficial do Apple Log pra Rec.709 e recebe o look escolhido. O arquivo que sobe já é o final, sem esperar a VPS." : "Desligado: sobe o Apple Log original (10 bits) pra colorir; a VPS faz a cópia Rec.709 + look depois.").font(.caption2)
        Toggle("Cópia Rec.709 na VPS (guarda o Log)", isOn: $camera.convertRec709).disabled(configuringDisabled || camera.bake709)
        Picker("Codec", selection: Binding(get: { camera.codec }, set: { camera.setCodec($0) })) {
          ForEach(camera.codecs, id: \.self) { codec in Text(codec == "hvc1" ? "HEVC" : codec == "avc1" ? "H.264" : codec).tag(codec) }
        }.disabled(configuringDisabled || camera.hdrEnabled || camera.logEnabled)
      }
      Section("Foco e luz") {
        Toggle("Travar luz e cor", isOn: Binding(get: { camera.colorLocked }, set: { camera.lockColor($0) })).disabled(!camera.ready)
        Toggle("Lanterna", isOn: Binding(get: { camera.torchEnabled }, set: { camera.setTorch($0) })).disabled(!camera.ready || !camera.torchAvailable)
        Toggle("Foco manual", isOn: Binding(get: { camera.manualFocus }, set: { camera.setFocus($0) })).disabled(!camera.ready || !camera.focusAvailable)
        if camera.manualFocus {
          Slider(value: Binding(get: { camera.lensPosition }, set: { camera.setFocus(true, position: $0) }), in: 0...1)
        }
        Text("Toque na imagem para focar e medir a luz naquele ponto.").font(.caption2)
        Toggle("ISO / obturador manuais", isOn: Binding(get: { camera.manualExposure }, set: { camera.setExposure($0) })).disabled(!camera.ready || !camera.exposureAvailable)
        if camera.manualExposure {
          Text("ISO \(Int(camera.iso)) · 1/\(Int(camera.shutter)) s").font(.caption).monospacedDigit()
          Slider(value: Binding(get: { max(camera.minISO, min(camera.maxISO, camera.iso)) }, set: { camera.setExposure(true, iso: $0) }), in: camera.minISO...max(camera.minISO + 1, camera.maxISO))
          Slider(value: Binding(get: { max(camera.minShutter, min(camera.maxShutter, camera.shutter)) }, set: { camera.setExposure(true, shutter: $0) }), in: camera.minShutter...max(camera.minShutter + 1, camera.maxShutter))
        } else {
          Text(String(format: "Compensação: %+.1f EV", camera.exposureBias)).font(.caption)
          Slider(value: Binding(get: { camera.exposureBias }, set: { camera.setExposureBias($0) }), in: camera.minExposureBias...max(camera.minExposureBias + 0.1, camera.maxExposureBias)).disabled(!camera.ready || camera.colorLocked)
        }
        Toggle("Balanço de branco manual", isOn: Binding(get: { camera.manualWhiteBalance }, set: { camera.setWhiteBalance($0) })).disabled(!camera.ready || !camera.whiteBalanceAvailable)
        if camera.manualWhiteBalance {
          Text("\(Int(camera.temperature)) K").font(.caption)
          Slider(value: Binding(get: { max(2000, min(10000, camera.temperature)) }, set: { camera.setWhiteBalance(true, temperature: $0) }), in: 2000...10000)
        }
        Text(camera.status).font(.caption2)
      }
    }
  }
}
