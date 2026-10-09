import SwiftUI
import simd

// Ferramentas sobre a imagem (as mesmas do Rec web): grade, nível, enquadramento, moldura do Instagram e chão 3D.
// Tudo é guia na tela — o arquivo sai sempre com o quadro inteiro do sensor; formato/moldura/espaço vão junto na tomada.
final class OverlayState: ObservableObject {
  private static let d = UserDefaults.standard
  @Published var grid = OverlayState.d.object(forKey: "t_grid") as? Bool ?? true { didSet { Self.d.set(grid, forKey: "t_grid") } }
  @Published var gridKind = OverlayState.d.string(forKey: "t_grid_kind") ?? "tercos" { didSet { Self.d.set(gridKind, forKey: "t_grid_kind") } }   // tercos | quadriculado
  @Published var level = OverlayState.d.object(forKey: "t_level") as? Bool ?? true { didSet { Self.d.set(level, forKey: "t_level") } }
  @Published var space = OverlayState.d.bool(forKey: "t_space") { didSet { Self.d.set(space, forKey: "t_space") } }
  @Published var aspect = OverlayState.d.string(forKey: "t_aspect") ?? "9:16" { didSet { Self.d.set(aspect, forKey: "t_aspect") } }
  @Published var frame = OverlayState.d.string(forKey: "t_frame") ?? "" { didSet { Self.d.set(frame, forKey: "t_frame") } }      // "" | reels | stories | feed | anuncio
  @Published var frameUI = OverlayState.d.object(forKey: "t_frame_ui") as? Bool ?? true { didSet { Self.d.set(frameUI, forKey: "t_frame_ui") } }
  @Published var height = OverlayState.d.object(forKey: "t_height") as? Double ?? 1.5 { didSet { Self.d.set(height, forKey: "t_height") } }
  @Published var fovAdj = OverlayState.d.object(forKey: "t_fov") as? Double ?? 1.0 { didSet { Self.d.set(fovAdj, forKey: "t_fov") } }
  @Published var floor: Floor?
  struct Floor { var yaw: Double; var ox: Double; var oy: Double }
  func meta(zoom: Double, fov: Double) -> [String: Any] {
    ["height": (height * 1000).rounded() / 1000, "floor_set": floor != nil, "yaw0": floor?.yaw ?? 0, "origin": floor.map { [$0.ox, $0.oy] as Any } ?? (NSNull() as Any),
     "aspect": aspect, "frame": frame, "zoom": zoom, "fov_adj": fovAdj, "space_guide": space]
  }
}

enum Geometry {
  static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return rect }
    let s = min(rect.width / size.width, rect.height / size.height)
    let w = size.width * s, h = size.height * s
    return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
  }
}

struct CameraOverlay: View {
  let video: CGRect
  let interfaceAngle: Double          // 90 retrato · 0/180 deitado
  @ObservedObject var tools: OverlayState
  @ObservedObject var camera: NativeCamera
  private let gold = Color(red: 1, green: 0.8, blue: 0)
  var crop: CGRect {
    let c = Framing.crop(width: video.width, height: video.height, ratio: Framing.ratio(tools.aspect))
    return CGRect(x: video.minX + c.x, y: video.minY + c.y, width: c.w, height: c.h)
  }
  var body: some View {
    ZStack {
      if Framing.ratio(tools.aspect) > 0 { mask }
      if tools.grid && !camera.recording { grid }
      if !tools.frame.isEmpty && !camera.recording { instagram }
      if (tools.level || tools.space) && !camera.front && !camera.recording {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in   // 20 Hz basta pro nível (era até 120 Hz: calor)
          Canvas { ctx, _ in
            guard let m = MotionHub.shared.snapshot() else { return }
            if tools.space { drawFloor(ctx, m) }
            if tools.level { drawLevel(ctx, m) }
          }
        }
      }
    }
    .allowsHitTesting(false)
  }
  private var mask: some View {
    Canvas { ctx, size in
      var p = Path(CGRect(origin: .zero, size: size)); p.addRect(crop)
      ctx.fill(p, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
      ctx.stroke(Path(crop), with: .color(.white.opacity(0.5)), lineWidth: 1)
    }
  }
  private var grid: some View {
    Canvas { ctx, _ in
      let r = crop; var p = Path()
      let n = tools.gridKind == "quadriculado" ? 4 : 3
      for i in 1..<n {
        let x = r.minX + r.width * CGFloat(i) / CGFloat(n), y = r.minY + r.height * CGFloat(i) / CGFloat(n)
        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
      }
      ctx.stroke(p, with: .color(.white.opacity(0.35)), lineWidth: 0.8)
    }
  }
  // Moldura: interface do Instagram por cima do quadro 9:16 (o que fica coberto e a área segura).
  private var instagram: some View {
    Canvas { ctx, _ in
      let r = Geometry.fit(CGSize(width: 9, height: 16), in: crop)
      let H = r.height, W = r.width
      var zones: [CGRect] = [], safe = r
      switch tools.frame {
      case "reels":
        zones = [CGRect(x: r.minX, y: r.minY, width: W, height: H * 220 / 1920), CGRect(x: r.minX, y: r.maxY - H * 420 / 1920, width: W, height: H * 420 / 1920), CGRect(x: r.maxX - W * 150 / 1080, y: r.minY + H * 0.45, width: W * 150 / 1080, height: H * 0.33)]
        safe = CGRect(x: r.minX + W * 60 / 1080, y: r.minY + H * 220 / 1920, width: W - W * 210 / 1080, height: H - H * 640 / 1920)
      case "stories":
        zones = [CGRect(x: r.minX, y: r.minY, width: W, height: H * 0.14), CGRect(x: r.minX, y: r.maxY - H * 0.2, width: W, height: H * 0.2)]
        safe = CGRect(x: r.minX, y: r.minY + H * 0.14, width: W, height: H * 0.66)
      case "anuncio":
        zones = [CGRect(x: r.minX, y: r.minY, width: W, height: H * 0.14), CGRect(x: r.minX, y: r.maxY - H * 0.35, width: W, height: H * 0.35), CGRect(x: r.minX, y: r.minY, width: W * 0.06, height: H), CGRect(x: r.maxX - W * 0.06, y: r.minY, width: W * 0.06, height: H)]
        safe = CGRect(x: r.minX + W * 0.06, y: r.minY + H * 0.14, width: W * 0.88, height: H * 0.51)
      default:   // feed 4:5 (corte do perfil 3:4 também marcado)
        let f = Geometry.fit(CGSize(width: 4, height: 5), in: r), g = Geometry.fit(CGSize(width: 3, height: 4), in: r)
        zones = [CGRect(x: r.minX, y: r.minY, width: W, height: f.minY - r.minY), CGRect(x: r.minX, y: f.maxY, width: W, height: r.maxY - f.maxY)]
        safe = f
        ctx.stroke(Path(g), with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
      }
      if tools.frameUI { for z in zones { ctx.fill(Path(z), with: .color(Color(red: 0.9, green: 0.1, blue: 0.2).opacity(0.22))) } }
      ctx.stroke(Path(roundedRect: safe, cornerRadius: 6), with: .color(gold.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
    }
  }
  // gravidade no plano da tela -> ângulo do horizonte; amarelo e "encaixa" a menos de 1°
  private func screenTheta() -> Double { interfaceAngle == 0 ? .pi / 2 : interfaceAngle == 180 ? -.pi / 2 : 0 }
  private func drawLevel(_ ctx: GraphicsContext, _ m: MotionHub.Snapshot) {
    let g = m.gravity
    guard abs(g.z) < 0.9 else { return }
    let th = screenTheta()
    let sx = g.x * cos(th) - g.y * sin(th), sy = g.x * sin(th) + g.y * cos(th)
    var tilt = atan2(sx, -sy)
    while tilt > .pi / 4 { tilt -= .pi / 2 }; while tilt < -.pi / 4 { tilt += .pi / 2 }
    let ok = abs(tilt) < .pi / 180
    let c = CGPoint(x: video.midX, y: video.midY), half = min(video.width, video.height) * 0.22
    let a = ok ? 0 : -tilt
    var line = Path()
    line.move(to: CGPoint(x: c.x - cos(a) * half, y: c.y - sin(a) * half)); line.addLine(to: CGPoint(x: c.x + cos(a) * half, y: c.y + sin(a) * half))
    var fixed = Path()
    fixed.move(to: CGPoint(x: c.x - half * 1.35, y: c.y)); fixed.addLine(to: CGPoint(x: c.x - half * 1.1, y: c.y))
    fixed.move(to: CGPoint(x: c.x + half * 1.1, y: c.y)); fixed.addLine(to: CGPoint(x: c.x + half * 1.35, y: c.y))
    ctx.stroke(fixed, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
    ctx.stroke(line, with: .color(ok ? gold : .white), lineWidth: ok ? 2.2 : 1.5)
  }
  // Chão 3D (3DoF): grade de 50 cm no piso, a `height` abaixo da câmera, presa no mundo pelo giroscópio.
  private func project(_ p: SIMD3<Double>, _ q: simd_quatd, _ f: Double, _ th: Double) -> CGPoint? {
    let d = q.inverse.act(p)
    let depth = -d.z
    guard depth > 0.08 else { return nil }
    let sx = d.x * cos(th) - d.y * sin(th), sy = d.x * sin(th) + d.y * cos(th)
    return CGPoint(x: video.midX + CGFloat(f * sx / depth), y: video.midY - CGFloat(f * sy / depth))
  }
  func focal() -> Double {
    let tanHalf = tan(camera.fieldOfView * .pi / 360) / max(1, camera.zoomFactorRaw)
    return Double(max(video.width, video.height)) / 2 / max(0.01, tanHalf) * tools.fovAdj
  }
  private func drawFloor(_ ctx: GraphicsContext, _ m: MotionHub.Snapshot) {
    let q = m.deviceToWorld, f = focal(), th = screenTheta(), h = tools.height
    let fl = tools.floor ?? OverlayState.Floor(yaw: 0, ox: 0, oy: 0)
    let cy = cos(fl.yaw), sy = sin(fl.yaw)
    func world(_ u: Double, _ v: Double) -> SIMD3<Double> { SIMD3(fl.ox + cy * u - sy * v, fl.oy + sy * u + cy * v, -h) }
    let span = 8.0, step = 0.5
    var k = -span
    while k <= span + 0.001 {
      for axis in 0..<2 {
        var path = Path(); var drawing = false
        var t = -span
        while t <= span + 0.001 {
          let w = axis == 0 ? world(k, t) : world(t, k)
          if let pt = project(w, q, f, th), simd_length(SIMD2(w.x, w.y)) < 14 {
            if drawing { path.addLine(to: pt) } else { path.move(to: pt); drawing = true }
          } else { drawing = false }
          t += 0.25
        }
        let main = abs(k) < 0.001
        let fade = max(0.12, 0.55 - abs(k) / span * 0.4)
        ctx.stroke(path, with: .color(main ? gold.opacity(0.95) : Color(red: 1, green: 0.85, blue: 0.3).opacity(fade)), lineWidth: main ? 1.8 : 0.9)
      }
      k += step
    }
    if tools.floor != nil, let o = project(world(0, 0), q, f, th) {
      ctx.fill(Path(ellipseIn: CGRect(x: o.x - 5, y: o.y - 5, width: 10, height: 10)), with: .color(gold))
    }
  }
  // "Fixar chão": a origem vai pro ponto do piso no centro da imagem e a grade alinha com a direção da câmera.
  static func fixFloor(tools: OverlayState) -> String? {
    guard let m = MotionHub.shared.snapshot() else { return "Sensores ainda não responderam — mexa o celular" }
    let ray = m.deviceToWorld.act(SIMD3(0, 0, -1))
    guard ray.z < -0.05 else { return "Aponte o centro da imagem pro chão (1 a 3 m) e toque de novo" }
    let t = -tools.height / ray.z
    tools.floor = OverlayState.Floor(yaw: atan2(ray.y, ray.x), ox: ray.x * t, oy: ray.y * t)
    return nil
  }
}
