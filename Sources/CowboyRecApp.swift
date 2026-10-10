import SwiftUI
import AVFoundation

@main struct CowboyRecApp: App {
  var body: some Scene { WindowGroup { RecorderView() } }
}

// TOQUE (0.9.2): a prévia inteira pega o toque pra focar/medir luz; os vãos em volta dos botões caíam nela ("ponto de luz"
// ao errar o parar por pouco). A faixa de baixo e a coluna de ferramentas engolem o toque, cada botão tem área maior que o
// desenho e o foco ignora toque a menos de 14 pt dos controles.
struct ControlsTopKey: PreferenceKey {
  static var defaultValue: CGFloat = .infinity
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}
struct ToolsFrameKey: PreferenceKey {
  static var defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let n = nextValue(); if n != .zero { value = n } }
}

enum CameraTool: String, CaseIterable, Identifiable {
  case grid, level, space, lut, match, frame, aspect
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .grid: return "grid"
    case .level: return "level"
    case .space: return "cube.transparent"
    case .lut: return "camera.filters"
    case .match: return "circle.lefthalf.filled"
    case .frame: return "rectangle.dashed"
    case .aspect: return "aspectratio"
    }
  }
  var title: String {
    switch self {
    case .grid: return "Grade"
    case .level: return "Nível"
    case .space: return "3D"
    case .lut: return "LUT"
    case .match: return "Igualar"
    case .frame: return "Moldura"
    case .aspect: return "Enquadrar"
    }
  }
}

struct RecorderView: View {
  @StateObject private var camera = NativeCamera()
  @StateObject private var tools = OverlayState()
  @ObservedObject private var stream = CloudStream.shared
  @State private var portal: CowboyPortal?
  @State private var portalControl = CowboyPortalControl()
  @State private var captureWarning = false
  @State private var settings = false
  @State private var arPresentation = false
  @State private var panel: CameraTool?
  @State private var interfaceAngle: Double = 90
  @State private var pinchStart: Double?
  @State private var dialStart: Double?
  @State private var focusPoint: CGPoint?
  @State private var sunStart: Double?      // compensação de luz no começo do arrasto do sol
  @State private var focusToken = 0
  @State private var toast: String?
  @State private var iconAngle: Double = 0
  @State private var noisePanel = false
  @State private var askSelfTest = false
  @State private var fxOpen = false
  @State private var controlsTop: CGFloat = .infinity   // topo dos controles de baixo (coordenada da tela)
  @State private var toolsFrame: CGRect = .zero          // coluna de ferramentas (coordenada da tela)
  @Environment(\.scenePhase) private var phase
  private var cloud: CowboyCloud { .shared }
  private let gold = Color(red: 1, green: 0.8, blue: 0)
  private let rec = Color(red: 1, green: 0.23, blue: 0.19)

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      GeometryReader { geo in
        let video = videoRect(geo.size)
        ZStack {
          MetalPreview(renderer: camera.renderer)
            .frame(width: max(1, video.width), height: max(1, video.height))
            .position(x: video.midX, y: video.midY)
          CameraOverlay(video: video, interfaceAngle: interfaceAngle, tools: tools, camera: camera)
          Color.clear.contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
              guard video.contains(p) else { return }
              // perto dos controles (gravar/parar, lentes, pílula, ferramentas) nunca vira foco/luz
              let g = geo.frame(in: .global), pg = CGPoint(x: p.x + g.minX, y: p.y + g.minY)
              if pg.y > controlsTop - 14 || (toolsFrame != .zero && toolsFrame.insetBy(dx: -14, dy: -14).contains(pg)) { return }
              camera.focusAt(normalized: CGPoint(x: (p.x - video.minX) / video.width, y: (p.y - video.minY) / video.height))
              focusPoint = p; sunStart = nil; holdFocusUI()
            }
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { v in
              // SOL (luz), como na câmera do iPhone: arrastar pra cima clareia, pra baixo escurece (perto do quadrado)
              guard let fp = focusPoint, pinchStart == nil else { return }
              if sunStart == nil {
                guard hypot(v.startLocation.x - fp.x, v.startLocation.y - fp.y) < 140 else { return }
                sunStart = camera.exposureBias
              }
              let lo = camera.minExposureBias, hi = max(camera.minExposureBias, camera.maxExposureBias)
              camera.setExposureBias(max(lo, min(hi, (sunStart ?? 0) - Double(v.translation.height) / 90)))
              holdFocusUI()
            }.onEnded { _ in if sunStart != nil { sunStart = nil; holdFocusUI() } })
            .gesture(MagnifyGesture().onChanged { v in
              sunStart = nil
              if pinchStart == nil { pinchStart = camera.zoom }
              camera.followZoom(clampZoom((pinchStart ?? 1) * v.magnification))
            }.onEnded { _ in pinchStart = nil; camera.endZoomGesture() })
          if let p = focusPoint {
            // quadrado do foco + sol da luz ao lado (do outro lado perto da borda); trilho só enquanto arrasta
            let sx = p.x + 52 > geo.size.width - 18 ? p.x - 52 : p.x + 52
            let sy = p.y - CGFloat(max(-3, min(3, camera.exposureBias))) * 22
            ZStack {
              RoundedRectangle(cornerRadius: 3).stroke(gold, lineWidth: 1.5).frame(width: 74, height: 74).position(p)
              if sunStart != nil { Rectangle().fill(gold.opacity(0.7)).frame(width: 1, height: 140).position(x: sx, y: p.y) }
              Image(systemName: "sun.max.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(gold).shadow(radius: 2).position(x: sx, y: sy)
            }.allowsHitTesting(false).transition(.opacity)
          }
        }
        .onChange(of: geo.size) { _, _ in updateAngle() }
      }
      .ignoresSafeArea()
      controls
      if !camera.selfTest.isEmpty {
        Text(camera.selfTest).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center).padding(14)
          .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 30)
          .frame(maxHeight: .infinity, alignment: .top).padding(.top, 120).allowsHitTesting(false)
      }
      if let toast {
        Text(toast).font(.footnote).padding(.horizontal, 14).padding(.vertical, 9).background(.black.opacity(0.78), in: Capsule())
          .frame(maxHeight: .infinity, alignment: .center).allowsHitTesting(false)
      }
    }
    .tint(gold).preferredColorScheme(.dark).statusBarHidden(true).persistentSystemOverlays(.hidden)
    .fullScreenCover(item: $portal, onDismiss: {
      Task { await cloud.refresh(); if let owner = cloud.email { camera.recoverSaved(owner: owner) }; camera.start() }
    }) { destination in
      VStack(spacing: 0) {
        HStack {
          Text("Cowboy Rec · 0.5").font(.caption.weight(.bold))
          Spacer()
          Button("Voltar à câmera") {
            Task { if await portalControl.canReturnToCamera() { portal = nil } else { captureWarning = true } }
          }.buttonStyle(.borderedProminent)
        }.padding(12).background(Color.black)
        CowboyAccountView(destination: destination, control: portalControl)
      }
      .alert("Gravação em andamento", isPresented: $captureWarning) { Button("OK", role: .cancel) {} } message: { Text("Pare a gravação antes de voltar à câmera nativa.") }
      .preferredColorScheme(.dark)
    }
    .sheet(isPresented: $settings) { settingsSheet }
    .alert("Calibrar o zoom (45 s)", isPresented: $askSelfTest) {
      Button("Calibrar agora") { camera.runZoomCalibration() }
      Button("Depois", role: .cancel) {}
    } message: { Text("Apoie o celular PARADO num lugar iluminado, apontado pra algo com detalhes, e não toque. O app faz uns zooms sozinho, mede na imagem e só liga a correção do zoom se ela provar que a imagem para quieta.") }
    .onChange(of: camera.ready) { _, ok in
      if ok && !UserDefaults.standard.bool(forKey: "zoomcalib_075") { UserDefaults.standard.set(true, forKey: "zoomcalib_075"); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { askSelfTest = true } }
    }
    .fullScreenCover(isPresented: $arPresentation, onDismiss: { camera.start() }) { NativeARRecorderView() }
    .task {
      Diag.install(); Diag.step("open")
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      UIApplication.shared.isIdleTimerDisabled = true
      CloudStream.shared.cookieProvider = { await MainActor.run { CowboyCloud.shared.credential } }
      camera.spaceMeta = { [tools, camera] in tools.meta(zoom: camera.zoom, fov: camera.fieldOfView) }
      camera.onSaved = { file, owner in
        do {
          try cloud.enqueue(file, owner: owner)
          for suffix in ["owner", "capture", "ar"] { try? FileManager.default.removeItem(at: file.appendingPathExtension(suffix)) }
          try? FileManager.default.removeItem(at: file)
          camera.recoverableFile = nil
        } catch { camera.recoverableFile = file; camera.status = "Vídeo preservado: \(error.localizedDescription)" }
      }
      updateAngle()
      await cloud.refresh()
      if let owner = cloud.email { camera.recoverSaved(owner: owner); CloudStream.shared.resume(owner: owner); camera.start() } else { open(.account) }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      // tela travada em pé: só os ícones giram pra dar leitura (o vídeo usa o horizonte do aparelho)
      let o = UIDevice.current.orientation
      let a: Double? = o == .portrait ? 0 : o == .landscapeLeft ? 90 : o == .landscapeRight ? -90 : o == .portraitUpsideDown ? 180 : nil
      if let a, a != iconAngle { withAnimation(.easeInOut(duration: 0.25)) { iconAngle = a } }
    }
    .onChange(of: phase) { _, value in
      if value == .background { camera.close(); CloudStream.shared.enterBackground(); MotionHub.shared.stop() }
      else if value == .active && portal == nil && !arPresentation { camera.start(); Task { await cloud.refresh(); CloudStream.shared.kick() } }
    }
  }

  // em pé: a imagem começa logo abaixo da faixa de cima (como a câmera do iPhone); deitado: centralizada na tela inteira
  private func videoRect(_ size: CGSize) -> CGRect {
    let full = CGRect(origin: .zero, size: size)
    guard size.height > size.width else { return Geometry.fit(camera.videoSize, in: full) }
    let top = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.top ?? 47) + 74
    let area = CGRect(x: 0, y: top, width: size.width, height: max(100, size.height - top))
    var r = Geometry.fit(camera.videoSize, in: area)
    r.origin.y = area.minY
    return r
  }

  // ---------------------------------------------------------------- controles (respeitam a área segura)
  private var controls: some View {
    VStack(spacing: 0) {
      topBar
      HStack(alignment: .top) {
        if !camera.recording { toolColumn.transition(.opacity) }
        Spacer()
      }.padding(.leading, 10).padding(.top, 10)
      Spacer()
      VStack(spacing: 0) {
        if let panel, !camera.recording { panelView(panel).padding(.bottom, 10) }
        if fxOpen { fxPanel.padding(.bottom, 6).transition(.opacity) }
        fxPill.padding(.bottom, 2)   // efeitos e zoom (ícones) em destaque na prévia
        lensBar.padding(.bottom, 8)   // também gravando: tocar = zoom até a lente (0.8.1)
        if (!camera.recording && stream.pendingMB > 1) || (camera.recording && (stream.health == .offline || stream.health == .slow || stream.health == .error)) { uploadLine.padding(.bottom, 8) }
        bottomRow.padding(.bottom, 2)
      }
      .background(GeometryReader { g in Color.clear.preference(key: ControlsTopKey.self, value: g.frame(in: .global).minY) })
    }
    .onPreferenceChange(ControlsTopKey.self) { controlsTop = $0 }
    .onPreferenceChange(ToolsFrameKey.self) { toolsFrame = $0 }
    .animation(.easeOut(duration: 0.18), value: camera.recording)
    .animation(.easeOut(duration: 0.18), value: panel)
    .animation(.easeOut(duration: 0.18), value: fxOpen)
  }
  private var topBar: some View {
    VStack(spacing: 4) {
      HStack(spacing: 10) {
        Circle().fill(healthColor).frame(width: 8, height: 8).padding(8).background(.white.opacity(0.12), in: Circle())
        Button { settings = true } label: {
          HStack(spacing: 4) {
            Text(camera.formatShort).font(.system(size: 13, weight: .bold))
            if camera.logEnabled { Text("LOG").font(.system(size: 10, weight: .heavy)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.purple, in: RoundedRectangle(cornerRadius: 3)) }
            else if camera.hdrEnabled { Text("HDR").font(.system(size: 10, weight: .heavy)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.orange, in: RoundedRectangle(cornerRadius: 3)) }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
          }.foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.12), in: Capsule())
        }.disabled(camera.recording)
        Spacer()
        Text(timeText).font(.system(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(.white).rotationEffect(.degrees(abs(iconAngle) == 90 ? 0 : iconAngle))
          .padding(.horizontal, 10).padding(.vertical, 4).background(camera.recording ? rec : .white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        Spacer()
        if camera.torchAvailable {
          Button { camera.setTorch(!camera.torchEnabled) } label: { Image(systemName: camera.torchEnabled ? "bolt.fill" : "bolt.slash").font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34).background(camera.torchEnabled ? gold : .white.opacity(0.12), in: Circle()).foregroundStyle(camera.torchEnabled ? .black : .white).frame(width: 46, height: 46).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Lanterna")
        }
        Button { settings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34).background(.white.opacity(0.12), in: Circle()).foregroundStyle(.white).frame(width: 46, height: 46).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(camera.recording).accessibilityLabel("Ajustes")
      }
      AudioMeter(levels: camera.audioLevels, holds: camera.audioPeakHold, clip: camera.audioClip, noiseOn: camera.noiseLevel != .off) { withAnimation(.easeOut(duration: 0.15)) { noisePanel.toggle() } }
      if noisePanel {
        HStack(spacing: 6) {
          Text("Redutor de ruído").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
          ForEach(NoiseReducer.Level.allCases, id: \.rawValue) { l in
            pill(l.label, camera.noiseLevel == l) { camera.setNoise(l); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { withAnimation { noisePanel = false } } }
          }
        }.padding(.vertical, 2)
      }
      Text(statusLine).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.8)
    }
    .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 6)
    .frame(height: noisePanel ? 112 : 74, alignment: .top)
    .background(Color.black.ignoresSafeArea(edges: .top))
  }
  private var statusLine: String {
    if !camera.ready { return camera.status }
    var parts = ["v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"), "Estab. \(NativeCamera.label(camera.activeMode))"]
    if camera.logEnabled { parts.append(camera.rawLog ? "Apple Log (cru)" : "Apple Log → prévia Rec.709") }
    if !LookPreset.named(camera.lookID).neutral { parts.append("look \(LookPreset.named(camera.lookID).label)") }
    parts.append(camera.recording ? (stream.line.isEmpty ? "gravando direto na nuvem" : stream.line) : "grava direto na nuvem")
    if camera.bake709 && (camera.logEnabled || camera.hdrEnabled || !LookPreset.named(camera.lookID).neutral) { parts.append("arquivo Rec.709 + look") }
    if camera.droppedFrames > 0 { parts.append("\(camera.droppedFrames) quadros perdidos") }
    return parts.joined(separator: " · ")
  }
  private var timeText: String {
    let s = Int(camera.elapsed), h = s / 3600, m = (s / 60) % 60, x = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%02d:%02d", m, x)
  }
  private var healthColor: Color {
    switch stream.health {
    case .ok: return .green
    case .slow: return .yellow
    case .offline, .error: return rec
    case .idle: return cloud.email == nil ? rec : .green
    }
  }

  // ---------------------------------------------------------------- ferramentas (chaves independentes, como no Rec web)
  private func isOn(_ t: CameraTool) -> Bool {
    switch t {
    case .grid: return tools.grid
    case .level: return tools.level
    case .space: return tools.space
    case .lut: return !LookPreset.named(camera.lookID).neutral || ((camera.logEnabled || camera.hdrEnabled) && !camera.rawLog)
    case .match: return camera.lensMatchOn
    case .frame: return !tools.frame.isEmpty
    case .aspect: return tools.aspect != "livre"
    }
  }
  private func setOn(_ t: CameraTool, _ on: Bool) {
    switch t {
    case .grid: tools.grid = on
    case .level: tools.level = on
    case .space: tools.space = on; if on && tools.floor == nil { _ = CameraOverlay.fixFloor(tools: tools) }
    case .lut:
      if on { camera.setRawLog(false); if LookPreset.named(camera.lookID).neutral && !(camera.logEnabled || camera.hdrEnabled) { camera.setLook(UserDefaults.standard.string(forKey: "lastLook") ?? "cowboy") } }
      else { if !LookPreset.named(camera.lookID).neutral { UserDefaults.standard.set(camera.lookID, forKey: "lastLook") }; camera.setLook("natural"); camera.setRawLog(true) }
    case .match: camera.setLensMatch(on)
    case .frame: tools.frame = on ? (UserDefaults.standard.string(forKey: "lastFrame") ?? "reels") : ""
    case .aspect: tools.aspect = on ? (UserDefaults.standard.string(forKey: "lastAspect") ?? "9:16") : "livre"
    }
  }
  private var toolColumn: some View {
    VStack(spacing: 0) {
      ForEach(CameraTool.allCases) { t in
        Button {
          let on = isOn(t)
          if !on { setOn(t, true); panel = t == .level ? nil : t; flash(t.title) }
          else if panel == t || t == .level { setOn(t, false); panel = nil; flash(t.title + " desligado") }
          else { panel = t }
        } label: {
          Image(systemName: t.icon).font(.system(size: 17, weight: .semibold))
            .frame(width: 42, height: 42)
            .background(isOn(t) ? gold : Color.black.opacity(0.45), in: Circle())
            .overlay(Circle().stroke(panel == t ? Color.white : .clear, lineWidth: 1.5))
            .foregroundStyle(isOn(t) ? .black : .white)
            .rotationEffect(.degrees(iconAngle))
            .frame(width: 58, height: 50).contentShape(Rectangle())   // toque maior que o desenho
        }.buttonStyle(.plain).accessibilityLabel(t.title)
      }
    }
    .contentShape(Rectangle()).onTapGesture {}   // vão entre os ícones não vira foco
    .background(GeometryReader { g in Color.clear.preference(key: ToolsFrameKey.self, value: g.frame(in: .global)) })
  }
  @ViewBuilder private func panelView(_ t: CameraTool) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        switch t {
        case .grid:
          pill("Terços", tools.gridKind == "tercos") { tools.gridKind = "tercos" }
          pill("Quadriculado", tools.gridKind == "quadriculado") { tools.gridKind = "quadriculado" }
        case .level: EmptyView()
        case .space:
          pill(tools.floor == nil ? "Fixar chão" : "Refixar chão", tools.floor != nil) { if let e = CameraOverlay.fixFloor(tools: tools) { flash(e) } else { flash("Chão fixado — a grade fica presa no piso") } }
          stepper("altura", String(format: "%.2f m", tools.height).replacingOccurrences(of: ".", with: ",")) { tools.height = max(0.2, min(4, tools.height - 0.05)) } plus: { tools.height = max(0.2, min(4, tools.height + 0.05)) }
          stepper("lente", "\(Int((tools.fovAdj * 100).rounded()))%") { tools.fovAdj = max(0.6, min(1.6, tools.fovAdj - 0.02)) } plus: { tools.fovAdj = max(0.6, min(1.6, tools.fovAdj + 0.02)) }
          pill("Soltar", false) { tools.floor = nil }
          pill("AR 6DoF…", false) { panel = nil; camera.close { Task { @MainActor in arPresentation = true } } }
        case .lut:
          if camera.logEnabled || camera.hdrEnabled {
            pill(camera.logEnabled ? "Rec.709" : "HLG→709", !camera.rawLog) { camera.setRawLog(false) }
            pill(camera.logEnabled ? "LOG cru" : "HLG cru", camera.rawLog) { camera.setRawLog(true) }
            Divider().frame(height: 20)
          }
          ForEach(LookPreset.all) { l in pill(l.label, camera.lookID == l.id) { camera.setLook(l.id); if !l.neutral { UserDefaults.standard.set(l.id, forKey: "lastLook") } } }
        case .match:
          ForEach([("ultra", "0,5×"), ("tele", "5×")], id: \.0) { item in
            let n = camera.lensMatchStatus[item.0] ?? 0
            pill(n > 0 ? "\(item.1) igualada (\(n))" : "\(item.1) aprendendo…", n > 0) {}
          }
          pill("Reaprender", false) { camera.resetLensMatch(); flash("Passe o zoom devagar por 1× e por 5× apontando pra mesma cena") }
        case .frame:
          ForEach([("reels", "Reels"), ("stories", "Stories"), ("feed", "Feed 4:5"), ("anuncio", "Anúncio")], id: \.0) { item in
            pill(item.1, tools.frame == item.0) { tools.frame = item.0; UserDefaults.standard.set(item.0, forKey: "lastFrame") }
          }
          pill("Zonas", tools.frameUI) { tools.frameUI.toggle() }
        case .aspect:
          ForEach(Framing.options, id: \.id) { o in pill(o.label, tools.aspect == o.id) { tools.aspect = o.id; if o.id != "livre" { UserDefaults.standard.set(o.id, forKey: "lastAspect") } } }
        }
      }.padding(.horizontal, 14)
    }
    .frame(height: 40)
  }
  // ---------------------------------------------------------------- efeitos: LIVE/RENDER · desfoque · velocidade do zoom (ícones)
  static func blurIcon(_ a: Int) -> String { a >= 720 ? "aqi.high" : a >= 360 ? "aqi.medium" : "aqi.low" }
  static func speedIcon(_ i: Int) -> String { i == 0 ? "hare.fill" : i == 2 ? "tortoise.fill" : "gauge.with.dots.needle.50percent" }
  static func blurName(_ a: Int) -> String { a >= 720 ? "pesado 720°" : a >= 360 ? "forte 360°" : "natural 180°" }
  private var fxPill: some View {
    Button { fxOpen.toggle() } label: {
      HStack(spacing: 10) {
        Image(systemName: camera.fxRender ? "cloud.fill" : "bolt.fill")
        Image(systemName: "wind").opacity(camera.motionBlur ? 1 : 0.35)
        Image(systemName: Self.speedIcon(camera.zoomSpeed))
      }
      .font(.system(size: 13, weight: .bold))
      .padding(.horizontal, 12).padding(.vertical, 7)
      .background(camera.motionBlur ? gold : Color.black.opacity(0.55), in: Capsule())
      .foregroundStyle(camera.motionBlur ? .black : .white)
      .overlay(Capsule().stroke(.white.opacity(fxOpen ? 0.9 : 0), lineWidth: 1.5))
      .padding(.horizontal, 14).padding(.vertical, 6).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel("Efeitos e zoom")
  }
  private func iconPill(_ symbol: String, _ on: Bool, _ label: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
        .frame(width: 40, height: 40)
        .background(on ? gold : Color.black.opacity(0.55), in: Circle())
        .foregroundStyle(on ? .black : .white)
        .rotationEffect(.degrees(iconAngle))
        .frame(width: 46, height: 48).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(label)
  }
  private var fxPanel: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        iconPill("bolt.fill", !camera.fxRender, "Live") { camera.setFXRender(false); flash("Live: efeito na hora, na tela e no arquivo") }.disabled(camera.recording)
        iconPill("cloud.fill", camera.fxRender, "Render") { camera.setFXRender(true); flash("Render: grava limpo, a nuvem aplica depois") }.disabled(camera.recording)
        if camera.fxRender { iconPill(camera.previewAsRender ? "eye.fill" : "eye", camera.previewAsRender, "Ver como render") { camera.setPreviewAsRender(!camera.previewAsRender); flash(camera.previewAsRender ? "Tela mostra o render" : "Tela limpa (render só no arquivo)") } }
        Divider().frame(height: 26).padding(.horizontal, 4)
        iconPill("wind", camera.motionBlur, "Desfoque de movimento") { camera.setMotionBlur(!camera.motionBlur); flash(camera.motionBlur ? "Desfoque de movimento ligado" : "Desfoque de movimento desligado") }
        if camera.motionBlur {
          ForEach(MotionBlur.angles, id: \.self) { a in iconPill(Self.blurIcon(a), camera.blurAngle == a, "Desfoque " + Self.blurName(a)) { camera.setBlurAngle(a); flash("Desfoque " + Self.blurName(a)) } }
        }
        Divider().frame(height: 26).padding(.horizontal, 4)
        ForEach(NativeCamera.zoomSpeeds.indices, id: \.self) { i in
          iconPill(Self.speedIcon(i), camera.zoomSpeed == i, "Zoom " + NativeCamera.zoomSpeeds[i].label) { camera.setZoomSpeed(i); flash("Zoom " + NativeCamera.zoomSpeeds[i].label.lowercased()) }
        }
      }.padding(.horizontal, 10)
    }
    .frame(height: 50)
    .contentShape(Rectangle()).onTapGesture {}
  }
  private func pill(_ text: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(text).font(.system(size: 13, weight: on ? .bold : .medium)).padding(.horizontal, 13).padding(.vertical, 8)
        .background(on ? gold : Color.black.opacity(0.55), in: Capsule()).foregroundStyle(on ? .black : .white)
    }.buttonStyle(.plain)
  }
  private func stepper(_ label: String, _ value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
    HStack(spacing: 6) {
      Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
      Button(action: minus) { Image(systemName: "minus").frame(width: 26, height: 26).background(.white.opacity(0.12), in: Circle()) }.buttonStyle(.plain)
      Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(minWidth: 44)
      Button(action: plus) { Image(systemName: "plus").frame(width: 26, height: 26).background(.white.opacity(0.12), in: Circle()) }.buttonStyle(.plain)
    }.foregroundStyle(.white).padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 3).background(Color.black.opacity(0.55), in: Capsule())
  }

  // ---------------------------------------------------------------- zoom: lentes (rampa contínua) + roda (arrastar) + pinça
  private func clampZoom(_ z: Double) -> Double { max(camera.minimumZoom, min(camera.maximumZoom, z)) }
  private var activePreset: Double? {
    if camera.ultraLock, let first = camera.zoomPresets.first, first < 0.99 { return first }
    return camera.zoomPresets.min { abs(log($0 / max(0.01, camera.zoom))) < abs(log($1 / max(0.01, camera.zoom))) }
  }
  private var lensBar: some View {
    HStack(spacing: 6) {
      ForEach(camera.zoomPresets, id: \.self) { value in
        let current = activePreset == value
        Button {
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          camera.selectZoom(value)
        } label: {
          Text(current ? ZoomMath.label(camera.zoom) : ZoomMath.label(value).replacingOccurrences(of: "×", with: ""))
            .font(.system(size: current ? 13 : 12, weight: .bold)).monospacedDigit()
            .foregroundStyle(current ? gold : .white)
            .frame(minWidth: current ? 44 : 34, minHeight: current ? 44 : 34)
            .background(Color.black.opacity(0.5), in: Circle())
            .rotationEffect(.degrees(iconAngle))
            .frame(minWidth: 46, minHeight: 50).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
    }
    .padding(5).background(Color.black.opacity(0.28), in: Capsule())
    .contentShape(Capsule())
    .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { v in
      if dialStart == nil { dialStart = camera.zoom }
      camera.followZoom(clampZoom((dialStart ?? 1) * pow(2, -Double(v.translation.width) / 110)))
    }.onEnded { _ in dialStart = nil; camera.endZoomGesture() })
    .disabled(!camera.ready)
    .opacity(camera.zoomPresets.isEmpty ? 0 : 1)
  }
  private var uploadLine: some View {
    HStack(spacing: 6) {
      Image(systemName: stream.health == .offline ? "icloud.slash" : "icloud.and.arrow.up").font(.system(size: 11, weight: .bold))
      Text(stream.line.isEmpty ? "Subindo pra nuvem" : stream.line).lineLimit(1)
      if stream.pendingMB > 1 { Text(String(format: "· %.0f MB na fila%@", stream.pendingMB, stream.diskMB > 1 ? " (iPhone)" : "")) }
    }
    .font(.system(size: 11, weight: .semibold)).foregroundStyle(stream.health == .offline || stream.health == .error ? rec : stream.health == .slow ? .yellow : .white.opacity(0.85))
    .padding(.horizontal, 10).padding(.vertical, 4).background(Color.black.opacity(0.45), in: Capsule())
  }
  // rodapé SEM fundo: só os três botões sobre a imagem. Área de toque (0.9.2): gravar = 150 pt de largura na faixa inteira,
  // PARAR (gravando) = 220 pt; galeria e câmera = 84 pt; o resto da faixa engole o toque (nunca vira foco/luz)
  private var bottomRow: some View {
    HStack(spacing: 0) {
      Button { open(.library) } label: {
        Group {
          if let thumb = camera.lastThumb {
            Image(uiImage: thumb).resizable().scaledToFill().frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 12))
              .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.8), lineWidth: 1.5))
          } else {
            Image(systemName: "photo.stack").font(.system(size: 20, weight: .semibold)).frame(width: 50, height: 50)
              .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
          }
        }.rotationEffect(.degrees(iconAngle))
          .frame(width: 84, height: 100).contentShape(Rectangle())
      }.buttonStyle(.plain).opacity(camera.recording ? 0 : 1).disabled(camera.recording || camera.finishing).accessibilityLabel("Galeria")
      Spacer(minLength: 0)
      Button(action: shutter) {
        ZStack {
          Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
          RoundedRectangle(cornerRadius: camera.recording ? 7 : 31).fill(rec).frame(width: camera.recording ? 30 : 62, height: camera.recording ? 30 : 62)
          if camera.finishing { ProgressView().tint(.white) }
        }
        .frame(width: camera.recording ? 220 : 150, height: 100).contentShape(Rectangle())
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: camera.recording)
      }.buttonStyle(.plain).disabled(!camera.ready || camera.finishing).accessibilityLabel(camera.recording ? "Parar gravação" : "Gravar")
      Spacer(minLength: 0)
      Button { camera.flip() } label: {
        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 20, weight: .semibold)).frame(width: 50, height: 50)
          .background(Color.black.opacity(0.45), in: Circle()).foregroundStyle(.white).rotationEffect(.degrees(iconAngle))
          .frame(width: 84, height: 100).contentShape(Rectangle())
      }.buttonStyle(.plain).opacity(camera.recording ? 0 : 1).disabled(camera.recording || camera.finishing || !camera.ready).accessibilityLabel("Trocar câmera")
    }
    .padding(.horizontal, 10)
    .frame(height: 100)
    .contentShape(Rectangle()).onTapGesture {}   // a faixa inteira nunca vira foco/luz
  }

  // ---------------------------------------------------------------- ajustes
  private var settingsSheet: some View {
    NavigationStack {
      Form {
        NativeCameraSettings(camera: camera, configuringDisabled: camera.recording || camera.finishing || !camera.ready)
        Section("Direto na nuvem (VPS)") {
          Picker("Taxa de gravação", selection: Binding(get: { camera.bitrateChoice }, set: { camera.setBitrate($0) })) {
            ForEach(NativeCamera.bitrates.indices, id: \.self) { i in Text(NativeCamera.bitrates[i].label).tag(i) }
          }.disabled(camera.recording)
          Text("Cada segundo gravado sobe na hora pra biblioteca da VPS (MP4 fragmentado com recibo). O iPhone só segura o que a internet não acompanhar e apaga assim que sobe. 4K 60 em HEVC ≈ 50–80 Mb/s: no 4G, use 35 ou 20 Mb/s pra não acumular fila.").font(.caption2)
          Text(stream.line.isEmpty ? "Sem envios pendentes" : stream.line).font(.caption)
          if stream.pendingMB > 0.5 { Text(String(format: "Na fila: %.0f MB (%.0f MB guardados no iPhone)", stream.pendingMB, stream.diskMB)).font(.caption) }
          Button("Retomar envios") { Task { await cloud.refresh(); CloudStream.shared.kick() } }
          Button("Calibrar o zoom (45 s, celular parado)") { settings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { camera.runZoomCalibration() } }.disabled(camera.recording)
        }
        Section("Conta e biblioteca") {
          Text(cloud.email ?? "Você ainda não entrou na conta")
          Text(cloud.status).font(.caption)
          Button("Entrar / gerenciar conta") { settings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { open(.account) } }.disabled(camera.recording || camera.finishing)
          Button("Rec completo (web: ao vivo, chroma, galeria)") { settings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { open(.rec) } }.disabled(camera.recording || camera.finishing)
          if let file = camera.recoverableFile { ShareLink("Exportar captura preservada", item: file) }
        }
        Section("Espaço 3D com posição (ARKit)") {
          Button("Chão 3D / rastreamento 6DoF") {
            settings = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { camera.close { Task { @MainActor in arPresentation = true } } }
          }.disabled(camera.recording || camera.finishing)
          Text("O botão 3D da câmera é o guia pelo giroscópio (gira em volta). Este modo rastreia também o deslocamento (ARKit) e manda as poses pro Blender; usa os formatos do ARKit, sem Apple Log nem estabilização.").font(.caption2)
        }
      }.navigationTitle("Câmera").toolbar { Button("OK") { settings = false } }
    }.presentationDetents([.medium, .large])
  }

  // ---------------------------------------------------------------- ações
  private func shutter() {
    if camera.recording { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); camera.stopRecording(); return }
    guard let owner = cloud.email else { open(.account); return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    withAnimation(.easeOut(duration: 0.15)) { panel = nil }
    camera.record(owner: owner, aspect: tools.aspect, look: LookPreset.named(camera.lookID))
  }
  private func open(_ destination: CowboyPortal) { camera.close(); portal = destination }
  // o quadrado e o sol ficam 3 s depois do último toque/arrasto (como no iPhone) e somem devagar
  private func holdFocusUI() {
    focusToken += 1; let tk = focusToken
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if focusToken == tk && sunStart == nil { withAnimation(.easeOut(duration: 0.35)) { focusPoint = nil } } }
  }
  private func flash(_ text: String) {
    toast = text
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { if toast == text { toast = nil } }
  }
  private func updateAngle() {
    let o = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation ?? .portrait
    let angle: Double = o == .landscapeLeft ? 180 : o == .landscapeRight ? 0 : o == .portraitUpsideDown ? 270 : 90
    if angle != interfaceAngle { interfaceAngle = angle }
    camera.setPreviewAngle(angle)
  }
}

// Medidor de áudio: uma barra por canal, verde até -12 dB, amarelo até -6, vermelho acima; traço = pico dos últimos 1,5 s;
// "CLIP" acende se estourar. Escala -60…0 dBFS.
struct AudioMeter: View {
  let levels: [Float]
  let holds: [Float]
  let clip: Bool
  var noiseOn = false
  var onMic: () -> Void = {}
  private func x(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db + 60) / 60))) }
  var body: some View {
    HStack(spacing: 6) {
      Button(action: onMic) {
        HStack(spacing: 2) {
          Image(systemName: "mic.fill").font(.system(size: 10, weight: .bold))
          if noiseOn { Image(systemName: "waveform.badge.minus").font(.system(size: 9, weight: .bold)) }
        }.foregroundStyle(levels.allSatisfy { $0 <= -79 } ? Color.red : noiseOn ? Color(red: 1, green: 0.8, blue: 0) : .white.opacity(0.8))
        .padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.12), in: Capsule())
      }.buttonStyle(.plain)
      VStack(spacing: 2) {
        ForEach(Array(levels.enumerated()), id: \.offset) { i, db in
          GeometryReader { g in
            ZStack(alignment: .leading) {
              Capsule().fill(Color.white.opacity(0.12))
              LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.78), .init(color: .yellow, location: 0.86), .init(color: .red, location: 0.95)], startPoint: .leading, endPoint: .trailing)
                .mask(alignment: .leading) { Capsule().frame(width: g.size.width * x(db)) }
              if i < holds.count { Rectangle().fill(Color.white).frame(width: 2).offset(x: max(0, g.size.width * x(holds[i]) - 2)) }
            }
          }.frame(height: levels.count > 1 ? 3 : 5)
        }
      }
      Text(clip ? "CLIP" : String(format: "%.0f", max(-60, levels.max() ?? -80)))
        .font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(clip ? Color.red : .white.opacity(0.75)).frame(width: 30, alignment: .trailing)
    }.frame(height: 12).padding(.horizontal, 2)
  }
}
