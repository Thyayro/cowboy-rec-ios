import CoreImage
import SwiftUI
import UIKit

// Telas da ÁREA DE FOTOGRAFIA (0.11.0): câmera de foto, galeria do app e revelação (filtros, ajustes Lumetri, IA por prompt).
private let gold = Color(red: 1, green: 0.8, blue: 0)

struct PhotoCameraView: View {
  let onVideo: () -> Void
  @StateObject private var cam = PhotoCamera()
  @State private var pinchStart: Double?
  @State private var focusPoint: CGPoint?
  @State private var biasStart: Double?
  @State private var focusToken = 0
  @State private var blink = false
  @State private var gallery = false
  @State private var editShot: PhotoShot?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      GeometryReader { geo in
        let r = previewRect(geo.size)
        ZStack {
          PhotoPreview(camera: cam).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
          Color.clear.contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
              guard r.contains(p) else { return }
              cam.focus(atLayerPoint: CGPoint(x: p.x - r.minX, y: p.y - r.minY))
              focusPoint = p; biasStart = nil; holdFocus()
            }
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { v in
              guard let fp = focusPoint, pinchStart == nil else { return }
              if biasStart == nil {
                guard hypot(v.startLocation.x - fp.x, v.startLocation.y - fp.y) < 140 else { return }
                biasStart = cam.exposureBias
              }
              cam.setBias((biasStart ?? 0) - Double(v.translation.height) / 90); holdFocus()
            }.onEnded { _ in biasStart = nil })
            .gesture(MagnifyGesture().onChanged { v in
              if pinchStart == nil { pinchStart = cam.zoom }
              cam.setZoom((pinchStart ?? 1) * v.magnification)
            }.onEnded { _ in pinchStart = nil })
            .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
          if let p = focusPoint {
            let sx = p.x + 52 > geo.size.width - 18 ? p.x - 52 : p.x + 52
            ZStack {
              RoundedRectangle(cornerRadius: 3).stroke(gold, lineWidth: 1.5).frame(width: 74, height: 74).position(p)
              Image(systemName: "sun.max.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(gold)
                .position(x: sx, y: p.y - CGFloat(max(-3, min(3, cam.exposureBias))) * 22)
            }.allowsHitTesting(false)
          }
          // fora da proporção escolhida: escurecido (o arquivo sai recortado)
          let a = cam.aspect.rect(in: r)
          if a != r {
            Path { pth in pth.addRect(r); pth.addRect(a) }.fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            Rectangle().stroke(.white.opacity(0.35), lineWidth: 0.5).frame(width: a.width, height: a.height).position(x: a.midX, y: a.midY).allowsHitTesting(false)
          }
          if cam.switching { Color.black.opacity(0.85).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY).allowsHitTesting(false).transition(.opacity) }
          if blink { Color.black.frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY).allowsHitTesting(false) }
          if cam.countdown > 0 {
            Text("\(cam.countdown)").font(.system(size: 120, weight: .thin)).foregroundStyle(.white).shadow(radius: 6).position(x: r.midX, y: r.midY).allowsHitTesting(false)
          }
        }
      }.ignoresSafeArea()
      VStack(spacing: 0) {
        topBar
        Spacer()
        if !cam.status.isEmpty { Text(cam.status).font(.footnote).padding(8).background(.black.opacity(0.7), in: Capsule()).padding(.bottom, 8) }
        lensRow.padding(.bottom, 10)
        modeRow.padding(.bottom, 6)
        bottomRow
      }
    }
    .tint(gold).preferredColorScheme(.dark).statusBarHidden(true)
    .onAppear { cam.start() }
    .onDisappear { cam.stop() }
    .onChange(of: cam.shutterBlink) { _, _ in
      blink = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { withAnimation(.easeOut(duration: 0.18)) { blink = false } }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    .sheet(isPresented: $gallery, onDismiss: { cam.refreshLast() }) {
      PhotoGalleryView { shot in gallery = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editShot = shot } }
    }
    .fullScreenCover(item: $editShot, onDismiss: { cam.refreshLast() }) { PhotoEditorView(shot: $0) }
  }

  // em pé: quadro 3:4 logo abaixo da faixa de cima (como a câmera do iPhone)
  private func previewRect(_ size: CGSize) -> CGRect {
    let top = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.top ?? 47) + 54
    let w = size.width, h = min(size.height - top - 230, w * 4 / 3)
    return CGRect(x: (size.width - h * 3 / 4) / 2, y: top, width: h * 3 / 4, height: h)
  }
  private func holdFocus() {
    focusToken += 1; let t = focusToken
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if t == focusToken && biasStart == nil { withAnimation { focusPoint = nil } } }
  }

  private var topBar: some View {
    HStack(spacing: 8) {
      if cam.flashAvailable {
        circle(cam.flash.icon, cam.flash != .off) { cam.flash = PhotoFlash(rawValue: (cam.flash.rawValue + 1) % 3) ?? .off }.accessibilityLabel("Flash")
      }
      Menu {
        Picker("Formato", selection: $cam.format) {
          ForEach(PhotoFormat.allCases) { f in if !f.needsRaw || cam.rawSupported { Text(f.label).tag(f) } }
        }
        Picker("Proporção", selection: $cam.aspect) { ForEach(PhotoAspect.allCases) { Text($0.rawValue).tag($0) } }
        Picker("Resolução", selection: $cam.megapixels) { ForEach(cam.mpOptions, id: \.self) { Text("\($0) MP").tag($0) } }
        Toggle("Qualidade máxima (fusão de quadros)", isOn: $cam.maxQuality)
        Toggle("Salvar na Fototeca", isOn: $cam.saveToPhotos)
        if cam.position == .front { Toggle("Espelhar a frontal (igual à prévia)", isOn: $cam.mirrorFront) }
      } label: {
        HStack(spacing: 4) {
          Text(cam.effectiveFormat.label).font(.system(size: 12, weight: .heavy))
          Text("\(cam.megapixels) MP").font(.system(size: 12, weight: .semibold)).opacity(0.85)
          if !cam.maxQuality { Image(systemName: "hare.fill").font(.system(size: 10, weight: .bold)) }
          if cam.effectiveFormat.needsRaw { Text("RAW").font(.system(size: 9, weight: .heavy)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.purple, in: RoundedRectangle(cornerRadius: 3)) }
          else { Text("HDR").font(.system(size: 9, weight: .heavy)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.orange, in: RoundedRectangle(cornerRadius: 3)) }
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
        }.foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 7).background(.white.opacity(0.12), in: Capsule())
      }
      Button { withAnimation(.easeOut(duration: 0.15)) { cam.aspect = cam.aspect.next } } label: {
        Text(cam.aspect.rawValue).font(.system(size: 12, weight: .heavy)).frame(minWidth: 34).padding(.horizontal, 6).padding(.vertical, 7)
          .background(cam.aspect == .full ? Color.white.opacity(0.12) : gold, in: Capsule()).foregroundStyle(cam.aspect == .full ? Color.white : Color.black)
          .frame(height: 44).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Proporção " + cam.aspect.rawValue)
      Spacer()
      if abs(cam.exposureBias) > 0.05 {
        Button { cam.setBias(0) } label: { Text(String(format: "%+.1f EV", cam.exposureBias)).font(.system(size: 12, weight: .bold, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 6).background(gold, in: Capsule()).foregroundStyle(.black) }.buttonStyle(.plain)
      }
      circle(cam.timer == 0 ? "timer" : cam.timer == 3 ? "3.circle" : "10.circle", cam.timer > 0) { cam.timer = cam.timer == 0 ? 3 : cam.timer == 3 ? 10 : 0 }.accessibilityLabel("Temporizador")
      // 0.11.5: o canto de baixo virou o "virar câmera" (como no iPhone); revelar a última foto sobe pra cá.
      // Qualidade máxima × disparo rápido continua no menu (a lebre no rótulo = disparo rápido ligado).
      circle("camera.filters", false) { if let s = cam.lastShot { editShot = s } }.disabled(cam.lastShot == nil).opacity(cam.lastShot == nil ? 0.4 : 1).accessibilityLabel("Revelar a última foto")
    }
    .padding(.horizontal, 12).padding(.top, 6).frame(height: 54)
  }
  private func circle(_ symbol: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
        .background(on ? gold : .white.opacity(0.12), in: Circle()).foregroundStyle(on ? .black : .white)
        .frame(width: 44, height: 44).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
  private var lensRow: some View {
    HStack(spacing: 10) {
      ForEach(cam.lenses, id: \.self) { l in
        let near = cam.lenses.min(by: { abs(log($0 / cam.zoom)) < abs(log($1 / cam.zoom)) }) == l
        Button { cam.setZoom(l, animated: true) } label: {
          Text(near ? Self.zoomText(cam.zoom) : Self.zoomText(l, short: true))
            .font(.system(size: near ? 13 : 12, weight: .bold)).foregroundStyle(near ? gold : .white)
            .frame(width: near ? 42 : 34, height: near ? 42 : 34).background(.black.opacity(0.55), in: Circle())
            .frame(width: 48, height: 48).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
    }.padding(.horizontal, 6).background(.white.opacity(0.08), in: Capsule())
  }
  static func zoomText(_ z: Double, short: Bool = false) -> String {
    let v = z < 1 ? String(format: "%.1f", z).replacingOccurrences(of: ".", with: ",") : (abs(z - z.rounded()) < 0.05 ? String(format: "%.0f", z) : String(format: "%.1f", z).replacingOccurrences(of: ".", with: ","))
    return short ? v : v + "×"
  }
  private var modeRow: some View {
    HStack(spacing: 26) {
      Button { cam.stop { onVideo() } } label: { Text("VÍDEO").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).padding(.vertical, 8).contentShape(Rectangle()) }.buttonStyle(.plain)
      Text("FOTO").font(.system(size: 13, weight: .heavy)).foregroundStyle(gold)
    }
  }
  private var bottomRow: some View {
    HStack(spacing: 0) {
      Button { gallery = true } label: {
        Group {
          if let t = cam.lastThumb { Image(uiImage: t).resizable().scaledToFill().frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.8), lineWidth: 1.5)) }
          else { Image(systemName: "photo.on.rectangle").font(.system(size: 20, weight: .semibold)).frame(width: 50, height: 50).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)) }
        }.frame(width: 84, height: 100).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Fotos")
      Spacer(minLength: 0)
      Button { if cam.countdown > 0 { cam.cancelTimer() } else { cam.shoot() } } label: {
        ZStack {
          Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
          Circle().fill(.white).frame(width: 64, height: 64).scaleEffect(cam.inFlight > 0 ? 0.88 : 1)
          if cam.countdown > 0 { Image(systemName: "xmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.black) }
        }.frame(width: 150, height: 100).contentShape(Rectangle()).animation(.easeOut(duration: 0.12), value: cam.inFlight)
      }.buttonStyle(.plain).disabled(!cam.ready || cam.switching).accessibilityLabel("Fotografar")
      Spacer(minLength: 0)
      Button { withAnimation(.easeOut(duration: 0.15)) { cam.flip() } } label: {
        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 20, weight: .semibold)).frame(width: 50, height: 50)
          .background(cam.position == .front ? gold : .white.opacity(0.12), in: Circle()).foregroundStyle(cam.position == .front ? .black : .white)
          .rotationEffect(.degrees(cam.position == .front ? 180 : 0))
          .frame(width: 84, height: 100).contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(!cam.ready || cam.switching || cam.countdown > 0).accessibilityLabel(cam.position == .front ? "Usar a câmera traseira" : "Usar a câmera frontal")
    }.padding(.horizontal, 10).frame(height: 100).contentShape(Rectangle()).onTapGesture {}
  }
}

// APAGAR (0.11.5): segurar a foto → Apagar; "Selecionar" → marca várias (ou Tudo) → Apagar. Pergunta sempre se sai só do
// app ou do app E da Fototeca (o iOS confirma de novo e guarda 30 dias em Apagados Recentemente).
struct PhotoDeleteConfirm: ViewModifier {
  @Binding var target: [PhotoShot]?
  let done: (Int, String?) -> Void
  func body(content: Content) -> some View {
    let n = target?.count ?? 0
    content.confirmationDialog(n == 1 ? "Apagar esta foto?" : "Apagar \(n) fotos?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), titleVisibility: .visible) {
      if let t = target {
        Button("Apagar do app e da Fototeca", role: .destructive) { target = nil; PhotoStore.delete(t, fromLibrary: true, done: done) }
        Button("Apagar só do app", role: .destructive) { target = nil; PhotoStore.delete(t, fromLibrary: false, done: done) }
      }
      Button("Cancelar", role: .cancel) { target = nil }
    } message: { Text("Na Fototeca a foto vai pra Apagados Recentemente (dá pra recuperar por 30 dias). No app não tem volta.") }
  }
}

struct PhotoGalleryView: View {
  let onPick: (PhotoShot) -> Void
  @State private var shots = PhotoStore.all()
  @State private var thumbs: [String: UIImage] = [:]
  @State private var selecting = false
  @State private var selected: Set<String> = []
  @State private var toDelete: [PhotoShot]?
  @State private var note: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ScrollView {
        if shots.isEmpty { Text("Nenhuma foto ainda.").foregroundStyle(.secondary).padding(.top, 60) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 3)], spacing: 3, pinnedViews: [.sectionHeaders]) {
          ForEach([false, true], id: \.self) { ai in
            let list = shots.filter { $0.isAI == ai }
            if !list.isEmpty {
              Section {
                ForEach(list) { s in cell(s) }
              } header: {
                HStack {
                  Text(ai ? "Geradas pela IA" : "Fotos").font(.subheadline.bold())
                  if ai { Text("ficam só no app até você Salvar").font(.caption).foregroundStyle(.secondary) }
                  Spacer()
                  if selecting && ai { Button("Marcar todas") { list.forEach { selected.insert($0.id) } }.font(.caption) }
                }.padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.85))
              }
            }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        if selecting {
          HStack {
            Button(selected.count == shots.count && !shots.isEmpty ? "Nenhuma" : "Tudo") { selected = selected.count == shots.count ? [] : Set(shots.map(\.id)) }
            Spacer()
            Text(selected.isEmpty ? "Toque nas fotos" : "\(selected.count) selecionada" + (selected.count == 1 ? "" : "s")).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { toDelete = shots.filter { selected.contains($0.id) } } label: { Label("Apagar", systemImage: "trash").bold() }
              .disabled(selected.isEmpty).tint(.red)
          }.padding(.horizontal, 18).padding(.vertical, 12).background(.bar)
        }
      }
      .overlay(alignment: .bottom) {
        if let note { Text(note).font(.footnote).padding(10).background(.black.opacity(0.85), in: Capsule()).padding(.bottom, selecting ? 70 : 20).transition(.opacity) }
      }
      .navigationTitle(selecting ? "Selecionar" : "Fotos").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if !shots.isEmpty || selecting { Button(selecting ? "Cancelar" : "Selecionar") { selecting.toggle(); selected = [] } }
        }
        ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } }
      }
      .modifier(PhotoDeleteConfirm(target: $toDelete) { n, msg in
        shots = PhotoStore.all()
        selected = selected.filter { id in shots.contains { $0.id == id } }
        if n > 0 { selecting = false; selected = [] }
        show(msg ?? (n == 1 ? "Foto apagada" : "\(n) fotos apagadas"))
      })
    }.preferredColorScheme(.dark)
  }
  @ViewBuilder private func cell(_ s: PhotoShot) -> some View {
    let on = selected.contains(s.id)
    Button { if selecting { toggle(s) } else { onPick(s) } } label: {
      ZStack(alignment: .topTrailing) {
        Color.white.opacity(0.06).aspectRatio(3 / 4, contentMode: .fit)
          .overlay { if let t = thumbs[s.id] { Image(uiImage: t).resizable().scaledToFill() } }.clipped()
          .overlay { if selecting && on { Color.black.opacity(0.35) } }
        HStack(spacing: 3) {
          if s.edited != nil { Image(systemName: "wand.and.stars").font(.system(size: 9, weight: .bold)) }
          if s.raw != nil || s.isRaw { Text("RAW").font(.system(size: 8, weight: .heavy)) }
          if s.isAI { Text("IA").font(.system(size: 8, weight: .heavy)) }
        }.padding(3).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3)).padding(4).foregroundStyle(.white)
        if selecting {
          Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24, weight: .semibold)).foregroundStyle(on ? gold : Color.white)
            .background(Circle().fill(on ? Color.black : Color.black.opacity(0.25)).padding(3))
            .shadow(radius: 2).padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
      }
    }.buttonStyle(.plain)
    .contextMenu {
      Button("Apagar", systemImage: "trash", role: .destructive) { toDelete = [s] }
      Button("Selecionar várias", systemImage: "checkmark.circle") { selecting = true; selected = [s.id] }
    }
    .task { if thumbs[s.id] == nil { let u = s.edited ?? s.main; let t = await Task.detached { PhotoStore.thumbnail(u, size: 300) }.value; thumbs[s.id] = t } }
  }
  private func toggle(_ s: PhotoShot) { if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) } }
  private func show(_ s: String) { withAnimation { note = s }; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if note == s { withAnimation { note = nil } } } }
}

// estado da revelação (fila própria; a prévia é uma cópia de até 1600 px, a exportação usa a resolução cheia)
final class PhotoEditModel: ObservableObject, @unchecked Sendable {
  let shot: PhotoShot
  let dev = PhotoDeveloper()
  @Published var adjust = PhotoAdjust() { didSet { if adjust != oldValue { render() } } }
  @Published var preview: UIImage?
  @Published var original: UIImage?
  @Published var lookThumbs: [String: UIImage] = [:]
  @Published var busy: String?
  @Published var aiNote: String?
  @Published var canUndo = false
  @Published var canRedo = false
  @Published var aiSaved: PhotoShot?     // último resultado da IA já guardado na galeria do app
  private var proxy: CIImage?, small: CIImage?, proxyScale: CGFloat = 1
  private var aiBase: CIImage?          // resultado da IA (vira a nova base; resolução que a IA devolveu)
  private var undo: [(ai: CIImage?, adjust: PhotoAdjust)] = []
  private var redo: [(ai: CIImage?, adjust: PhotoAdjust)] = []
  private var gen = 0
  private let queue = DispatchQueue(label: "cowboy.photo.dev", qos: .userInitiated)
  private func main(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

  let aspect: PhotoAspect
  init(shot: PhotoShot) { self.shot = shot; aspect = PhotoStore.aspect(shot.id); load() }
  private func load() {
    busy = "Abrindo…"
    queue.async {
      guard let full = self.dev.load(self.shot.source) else { self.main { self.busy = "Não abriu esta foto" }; return }
      let fullSide = max(full.image.extent.width, full.image.extent.height)
      let p = self.aspect.crop(self.dev.load(self.shot.source, maxSide: 1600)?.image ?? full.image)
      self.proxy = p; self.proxyScale = max(p.extent.width, p.extent.height) / max(1, fullSide)
      self.small = Self.shrink(p, 180)
      let orig = self.dev.cgImage(self.dev.develop(p, PhotoAdjust(), rawEV: false, scale: self.proxyScale)).map { UIImage(cgImage: $0) }
      self.main { self.original = orig; self.busy = nil; self.render(); self.makeLookThumbs() }
    }
  }
  static func shrink(_ i: CIImage, _ side: CGFloat) -> CIImage {
    let m = max(i.extent.width, i.extent.height); guard m > side else { return i }
    let s = i.transformed(by: CGAffineTransform(scaleX: side / m, y: side / m))
    return s.transformed(by: CGAffineTransform(translationX: -s.extent.minX, y: -s.extent.minY))
  }
  private var base: CIImage? { aiBase.map { Self.shrink($0, 1600) } ?? proxy }
  func render() {
    gen += 1; let g = gen, a = adjust
    queue.async {
      guard g == self.gen, let b = self.base else { return }
      let scale = self.aiBase == nil ? self.proxyScale : 1
      let img = self.dev.cgImage(self.dev.develop(b, a, rawEV: false, scale: scale)).map { UIImage(cgImage: $0) }
      self.main { if g == self.gen { self.preview = img } }
    }
  }
  func makeLookThumbs() {
    queue.async {
      guard let s = self.aiBase.map({ Self.shrink($0, 180) }) ?? self.small else { return }
      var out: [String: UIImage] = [:]
      for l in PhotoLook.all { var a = PhotoAdjust(); a.look = l.id; if let c = self.dev.cgImage(self.dev.develop(s, a, rawEV: false, scale: 0.1)) { out[l.id] = UIImage(cgImage: c) } }
      self.main { self.lookThumbs = out }
    }
  }
  // antes de cada mudança "de verdade" (fim do arrasto, filtro, IA): guarda pra desfazer
  // VOLTAR / AVANÇAR (0.11.5): toda mudança "de verdade" (IA, filtro, fim de arrasto) entra no histórico; voltar guarda o
  // estado atual pro avançar, e uma mudança nova depois de voltar apaga o que dava pra avançar (como em todo editor).
  func checkpoint() { undo.append((aiBase, adjust)); if undo.count > 30 { undo.removeFirst() }; redo.removeAll(); canUndo = true; canRedo = false }
  func undoLast() {
    guard let u = undo.popLast() else { return }
    redo.append((aiBase, adjust))
    go(u)
  }
  func redoNext() {
    guard let r = redo.popLast() else { return }
    undo.append((aiBase, adjust))
    go(r)
  }
  private func go(_ st: (ai: CIImage?, adjust: PhotoAdjust)) {
    let changedBase = (st.ai == nil) != (aiBase == nil) || st.ai !== aiBase
    aiBase = st.ai; adjust = st.adjust; canUndo = !undo.isEmpty; canRedo = !redo.isEmpty
    if changedBase { render(); makeLookThumbs() }
  }
  func resetAll() { checkpoint(); aiBase = nil; adjust = PhotoAdjust(); render(); makeLookThumbs() }

  func runAI(prompt: String, engine: PhotoAI.Engine, cookie: String?) {
    let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines); guard !p.isEmpty, busy == nil else { return }
    busy = engine == .openai ? "Editando com IA (OpenAI)…" : "Editando com IA (tentando o pool grátis primeiro)…"; aiNote = nil
    let a = adjust
    queue.async {
      guard let b = self.base else { self.main { self.busy = nil }; return }
      let shown = self.dev.develop(b, a, rawEV: false, scale: self.aiBase == nil ? self.proxyScale : 1)
      guard let jpg = self.dev.jpeg(shown, maxSide: 1536) else { self.main { self.busy = nil; self.aiNote = "Não deu pra preparar a foto" }; return }
      let ref = shown.extent
      Task { @MainActor in
        let t0 = Date()
        do {
          let r = try await PhotoAI.edit(jpeg: jpg, prompt: p, engine: engine, cookie: cookie)
          let fitted = PhotoAI.fit(r.image, toAspectOf: ref)
          self.checkpoint()
          self.aiBase = fitted
          self.adjust = PhotoAdjust()   // os ajustes já foram junto na foto enviada
          self.busy = nil
          let engineName = r.engine == "gratis" ? "pool grátis (\(r.model))" : r.engine == "openai" ? "OpenAI (\(r.model))" : r.model
          self.aiNote = String(format: "Feito por %@ em %.0f s · %d×%d px · guardada na galeria do app", engineName, Date().timeIntervalSince(t0), Int(fitted.extent.width), Int(fitted.extent.height))
          let sid = self.shot.id
          self.queue.async {
            guard let d = self.dev.heif(fitted), let saved = PhotoStore.saveAI(d, from: sid) else { Diag.step("photo-ai-save-fail", [:]); return }
            self.main { self.aiSaved = saved }
          }
          Diag.step("photo-ai", ["ok": true, "motor": r.engine, "modelo": r.model, "s": Int(Date().timeIntervalSince(t0)), "tentativas": r.tried.count])
          self.render(); self.makeLookThumbs()
        } catch {
          self.busy = nil; self.aiNote = error.localizedDescription
          Diag.step("photo-ai", ["ok": false, "erro": String(error.localizedDescription.prefix(300))])
        }
      }
    }
  }

  // exportação: base inteira (RAW em resolução cheia, ou o resultado da IA) com a receita → HEIF 10 bits P3 → app + Fototeca
  func export(done: @escaping (String) -> Void) {
    guard busy == nil else { return }
    busy = "Revelando em resolução cheia…"
    let a = adjust, ai = aiBase
    queue.async {
      let t0 = CACurrentMediaTime()
      guard let b = ai ?? self.dev.load(self.shot.source).map({ self.aspect.crop($0.image) }) else { self.main { self.busy = nil; done("Não abriu a foto original") }; return }
      let out = self.dev.develop(b, a, rawEV: false, scale: 1)
      guard let data = self.dev.heif(out) else { self.main { self.busy = nil; done("Não deu pra gerar o HEIF") }; return }
      let url = PhotoStore.dir.appendingPathComponent(self.shot.id + "-ed.heic")
      do { try data.write(to: url, options: .atomic) } catch { self.main { self.busy = nil; done("Sem espaço: \(error.localizedDescription)") }; return }
      Diag.step("photo-export", ["px": "\(Int(out.extent.width))x\(Int(out.extent.height))", "kb": data.count / 1024, "ms": Int((CACurrentMediaTime() - t0) * 1000), "ia": ai != nil, "filtro": a.look])
      PhotoStore.saveToLibrary(main: url, raw: nil, shotID: self.shot.id) { ok, err in self.main { self.busy = nil; done(ok ? "Salva na Fototeca" : "Ficou no app; Fototeca: \(err ?? "?")") } }
    }
  }
}

struct PhotoEditorView: View {
  @StateObject private var model: PhotoEditModel
  @Environment(\.dismiss) private var dismiss
  @State private var tab = 0
  @State private var prompt = ""
  @State private var engine: PhotoAI.Engine = .auto
  @State private var showOriginal = false
  @State private var toast: String?
  @State private var group = "Luz"
  @FocusState private var promptFocused: Bool
  @State private var toDelete: [PhotoShot]?
  @State private var aiDelete: [PhotoShot]?
  init(shot: PhotoShot) { _model = StateObject(wrappedValue: PhotoEditModel(shot: shot)) }

  var body: some View {
    VStack(spacing: 0) {
      header
      ZStack {
        Color.black
        if let img = showOriginal ? (model.original ?? model.preview) : model.preview {
          Image(uiImage: img).resizable().scaledToFit()
        } else { ProgressView().tint(.white) }
        if let b = model.busy { VStack(spacing: 8) { ProgressView().tint(.white); Text(b).font(.footnote) }.padding(14).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12)) }
        if showOriginal { Text("ORIGINAL").font(.system(size: 11, weight: .heavy)).padding(6).background(.black.opacity(0.6), in: Capsule()).frame(maxHeight: .infinity, alignment: .top).padding(.top, 8) }
        if let toast { Text(toast).font(.footnote).padding(10).background(.black.opacity(0.8), in: Capsule()).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 10) }
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, perform: {}, onPressingChanged: { showOriginal = $0 })
      Picker("", selection: $tab) { Text("Filtros").tag(0); Text("Ajustes").tag(1); Text("IA").tag(2) }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 8)
      Group {
        if tab == 0 { looksPanel } else if tab == 1 { adjustPanel } else { aiPanel }
      }.frame(height: 210)
    }
    .background(Color.black.ignoresSafeArea())
    .preferredColorScheme(.dark).tint(gold)
    .modifier(PhotoDeleteConfirm(target: $toDelete) { n, msg in if n > 0 { dismiss() } else if let msg { flash(msg) } })
    // apagar a imagem que a IA gerou (da galeria do app; se já foi salva, também pode sair da Fototeca) — a edição na tela continua
    .modifier(PhotoDeleteConfirm(target: $aiDelete) { n, msg in if n > 0 { model.aiSaved = nil; flash(msg ?? "Imagem da IA apagada") } else if let msg { flash(msg) } })
  }

  private var header: some View {
    HStack(spacing: 14) {
      Button("Fechar") { dismiss() }
      Button { toDelete = [model.shot] } label: { Image(systemName: "trash") }.disabled(model.busy != nil).accessibilityLabel("Apagar esta foto")
      Spacer()
      Button { model.undoLast() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo || model.busy != nil).accessibilityLabel("Voltar")
      Button { model.redoNext() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo || model.busy != nil).accessibilityLabel("Avançar")
      Button { model.resetAll() } label: { Image(systemName: "arrow.counterclockwise.circle") }.accessibilityLabel("Voltar ao original")
      Button { model.export { msg in flash(msg) } } label: { Text("Salvar").bold() }.buttonStyle(.borderedProminent).disabled(model.busy != nil)
    }.padding(.horizontal, 14).padding(.vertical, 10)
  }
  private func flash(_ s: String) { toast = s; DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if toast == s { toast = nil } } }

  private var looksPanel: some View {
    VStack(spacing: 10) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(PhotoLook.all) { l in
            Button {
              guard model.adjust.look != l.id else { return }
              model.checkpoint(); model.adjust.look = l.id; if model.adjust.lookAmount == 0 { model.adjust.lookAmount = 1 }
            } label: {
              VStack(spacing: 5) {
                Group { if let t = model.lookThumbs[l.id] { Image(uiImage: t).resizable().scaledToFill() } else { Color.white.opacity(0.08) } }
                  .frame(width: 74, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
                  .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.adjust.look == l.id ? gold : .clear, lineWidth: 2))
                Text(l.label).font(.system(size: 11, weight: model.adjust.look == l.id ? .bold : .regular)).foregroundStyle(model.adjust.look == l.id ? gold : .white).lineLimit(1)
              }.frame(width: 78)
            }.buttonStyle(.plain)
          }
        }.padding(.horizontal, 12)
      }
      if model.adjust.look != "natural" {
        HStack { Text("Intensidade").font(.caption); Slider(value: $model.adjust.lookAmount, in: 0...1, onEditingChanged: { e in if e { model.checkpoint() } }); Text("\(Int(model.adjust.lookAmount * 100))").font(.caption.monospacedDigit()).frame(width: 30) }.padding(.horizontal, 16)
      }
    }.padding(.top, 4)
  }

  private var adjustPanel: some View {
    VStack(spacing: 4) {
      Picker("", selection: $group) { Text("Luz").tag("Luz"); Text("Cor").tag("Cor"); Text("Efeitos").tag("Efeitos") }.pickerStyle(.segmented).padding(.horizontal, 40)
      ScrollView {
        VStack(spacing: 2) {
          ForEach(PhotoAdjust.sliders.filter { $0.group == group }) { s in
            HStack(spacing: 8) {
              Text(s.label).font(.system(size: 13)).frame(width: 92, alignment: .leading)
              Slider(value: Binding(get: { model.adjust[keyPath: s.path] }, set: { model.adjust[keyPath: s.path] = $0 }), in: s.range, onEditingChanged: { e in if e { model.checkpoint() } })
              Text(String(format: s.range.upperBound > 1 ? "%+.1f" : "%+.0f", s.range.upperBound > 1 ? model.adjust[keyPath: s.path] : model.adjust[keyPath: s.path] * 100))
                .font(.system(size: 11, design: .monospaced)).frame(width: 40, alignment: .trailing)
                .onTapGesture(count: 2) { model.checkpoint(); model.adjust[keyPath: s.path] = 0 }
            }.padding(.horizontal, 14).padding(.vertical, 2)
          }
          Text("Toque duas vezes no número pra zerar · segure a foto pra ver o original").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
        }
      }
    }
  }

  private var aiPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        TextField("Descreva a edição (ex.: céu de fim de tarde, tirar o poste, luz de estúdio)", text: $prompt, axis: .vertical)
          .lineLimit(1...3).focused($promptFocused).padding(10).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        Button {
          promptFocused = false
          model.runAI(prompt: prompt, engine: engine, cookie: CowboyCloud.shared.credential)
        } label: { Image(systemName: "wand.and.stars").font(.system(size: 18, weight: .bold)).frame(width: 44, height: 44).background(gold, in: Circle()).foregroundStyle(.black) }
          .buttonStyle(.plain).disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || model.busy != nil).accessibilityLabel("Editar com IA")
      }
      Picker("Motor", selection: $engine) { ForEach(PhotoAI.Engine.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
      HStack(spacing: 10) {
        Button { model.undoLast() } label: { Label("Voltar", systemImage: "chevron.backward") }.disabled(!model.canUndo || model.busy != nil)
        Button { model.redoNext() } label: { Label("Avançar", systemImage: "chevron.forward") }.disabled(!model.canRedo || model.busy != nil)
        Spacer()
        if let g = model.aiSaved {
          Button(role: .destructive) { aiDelete = [g] } label: { Label("Apagar a gerada", systemImage: "trash") }.disabled(model.busy != nil)
        }
      }.font(.footnote).buttonStyle(.bordered)
      if let n = model.aiNote { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
      else { Text("Grátis primeiro: tenta o Nano Banana (Gemini) nas chaves grátis e, sem cota, usa a OpenAI (gpt-image-1.5). A IA devolve até ~1,5 MP; os ajustes e filtros continuam valendo por cima.").font(.caption).foregroundStyle(.secondary) }
    }.padding(.horizontal, 14).padding(.top, 4)
  }
}
