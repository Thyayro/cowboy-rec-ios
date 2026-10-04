import SwiftUI
import AVFoundation

struct NativeCameraSettings: View {
  @ObservedObject var camera: NativeCamera
  let configuringDisabled: Bool
  var body: some View {
    Group {
      Section("Lente e formato reais") {
        Picker("Câmera",selection:Binding(get:{camera.lensID},set:{camera.selectLens($0)})) {
          ForEach(camera.lenses) { lens in Text(lens.name).tag(lens.id) }
        }.disabled(configuringDisabled || camera.lenses.isEmpty)
        Picker("Resolução / FPS",selection:Binding(get:{camera.profileID},set:{camera.selectProfile($0)})) {
          ForEach(camera.profiles) { profile in Text(profile.label).tag(profile.id) }
        }.disabled(configuringDisabled || camera.profiles.isEmpty)
        Toggle("HDR (HLG)",isOn:Binding(get:{camera.hdrEnabled},set:{camera.setHDR($0)})).disabled(configuringDisabled || !camera.hdrAvailable)
        Picker("Codec",selection:Binding(get:{camera.codec},set:{camera.setCodec($0)})) {
          ForEach(camera.codecs,id:\.self) { codec in Text(codec == "hvc1" ? "HEVC" : codec == "avc1" ? "H.264" : codec).tag(codec) }
        }.disabled(configuringDisabled || camera.hdrEnabled)
        Text(camera.status).font(.caption)
        Text("Estabilização ativa: \(NativeCamera.label(camera.activeMode))").font(.caption)
        Text("Os formatos são detectados na lente selecionada. Não há redução automática de resolução ou FPS para trocar de lente. Para escolher outra lente sem suporte ao formato atual, primeiro selecione um formato compatível.").font(.caption2)
      }
      Section("Foco e luz") {
        Toggle("Lanterna",isOn:Binding(get:{camera.torchEnabled},set:{camera.setTorch($0)})).disabled(!camera.ready || !camera.torchAvailable)
        Toggle("Foco manual",isOn:Binding(get:{camera.manualFocus},set:{camera.setFocus($0)})).disabled(!camera.ready || !camera.focusAvailable)
        if camera.manualFocus {
          Slider(value:Binding(get:{camera.lensPosition},set:{camera.setFocus(true,position:$0)}),in:0...1)
        }
        Text("Toque na imagem para focar naquele ponto.").font(.caption2)
        Toggle("ISO / obturador manuais",isOn:Binding(get:{camera.manualExposure},set:{camera.setExposure($0)})).disabled(!camera.ready || !camera.exposureAvailable)
        if camera.manualExposure {
          Text("ISO \(Int(camera.iso)) · 1/\(Int(camera.shutter)) s").font(.caption).monospacedDigit()
          Slider(value:Binding(get:{max(camera.minISO,min(camera.maxISO,camera.iso))},set:{camera.setExposure(true,iso:$0)}),in:camera.minISO...max(camera.minISO+1,camera.maxISO))
          Slider(value:Binding(get:{max(camera.minShutter,min(camera.maxShutter,camera.shutter))},set:{camera.setExposure(true,shutter:$0)}),in:camera.minShutter...max(camera.minShutter+1,camera.maxShutter))
        } else {
          Text(String(format:"Compensação: %+.1f EV",camera.exposureBias)).font(.caption)
          Slider(value:Binding(get:{camera.exposureBias},set:{camera.setExposureBias($0)}),in:camera.minExposureBias...max(camera.minExposureBias+0.1,camera.maxExposureBias)).disabled(!camera.ready || camera.colorLocked)
        }
        Toggle("Balanço de branco manual",isOn:Binding(get:{camera.manualWhiteBalance},set:{camera.setWhiteBalance($0)})).disabled(!camera.ready || !camera.whiteBalanceAvailable)
        if camera.manualWhiteBalance {
          Text("\(Int(camera.temperature)) K").font(.caption)
          Slider(value:Binding(get:{max(2000,min(10000,camera.temperature))},set:{camera.setWhiteBalance(true,temperature:$0)}),in:2000...10000)
        }
      }
    }
  }
}
