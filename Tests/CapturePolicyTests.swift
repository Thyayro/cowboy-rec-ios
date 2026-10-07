import Foundation
@main struct CapturePolicyTests {
  static func main() {
    let formats=[
      NativeFormatDescriptor(index:0,width:1920,height:1080,ranges:[NativeFrameRange(min:1,max:240)],hdr:false,stabilized:true),
      NativeFormatDescriptor(index:1,width:3840,height:2160,ranges:[NativeFrameRange(min:24,max:30)],hdr:true,stabilized:true),
      NativeFormatDescriptor(index:2,width:3840,height:2160,ranges:[NativeFrameRange(min:24,max:60)],hdr:false,stabilized:false),
      NativeFormatDescriptor(index:3,width:3840,height:2160,ranges:[NativeFrameRange(min:24,max:60)],hdr:false,stabilized:true)
    ]
    assert(NativeCapturePolicy.select(.main,hdr:false,formats:formats)==3)
    assert(NativeCapturePolicy.select(.main,hdr:true,formats:formats)==nil,"HDR may not silently downgrade 4K60 to 4K30")
    assert(NativeCapturePolicy.select(.main,hdr:false,formats:formats,log:true)==nil,"HDR support does not imply Apple Log support")
    let logFormats=[NativeFormatDescriptor(index:5,width:3840,height:2160,ranges:[NativeFrameRange(min:24,max:60)],hdr:false,stabilized:true,log:true)]
    assert(NativeCapturePolicy.select(.main,hdr:false,formats:logFormats,log:true)==5)
    assert(NativeCapturePolicy.profiles(formats,hdr:false,log:true).isEmpty)
    assert(NativeCapturePolicy.select(.main,hdr:false,formats:Array(formats.prefix(2)))==nil,"4K60 may not silently downgrade to HD240")
    let choices=NativeCapturePolicy.profiles(formats,hdr:false)
    assert(choices.contains(.main))
    assert(choices.contains(NativeCaptureProfile(width:1920,height:1080,fps:240)))
    assert(!choices.contains(NativeCaptureProfile(width:3840,height:2160,fps:120)))
    assert(NativeCapturePolicy.profiles(formats,hdr:true).allSatisfy { $0.width==3840 && $0.fps<=30 })
    let fractional=[NativeFormatDescriptor(index:4,width:1280,height:720,ranges:[NativeFrameRange(min:29.97,max:59.94)],hdr:false,stabilized:false)]
    assert(NativeCapturePolicy.select(NativeCaptureProfile(width:1280,height:720,fps:60),hdr:false,formats:fractional)==nil)
    assert(NativeCapturePolicy.profiles(fractional,hdr:false).contains(NativeCaptureProfile(width:1280,height:720,fps:59.94)))
    // 8-bit vs 10-bit: SDR prefers the lighter 8-bit format; Log needs the 10-bit one
    let bits=[NativeFormatDescriptor(index:7,width:3840,height:2160,ranges:[NativeFrameRange(min:1,max:60)],hdr:true,stabilized:true,log:true,tenBit:true),
      NativeFormatDescriptor(index:8,width:3840,height:2160,ranges:[NativeFrameRange(min:1,max:60)],hdr:false,stabilized:true,log:false,tenBit:false)]
    assert(NativeCapturePolicy.select(.main,hdr:false,formats:bits)==8)
    assert(NativeCapturePolicy.select(.main,hdr:false,formats:bits,log:true)==7)
    // color math agrees with the VPS LUT: 18% grey in Apple Log -> ~0.44 Rec.709 code
    let grey=0.0855047*log2(0.18+0.00964052)+0.69336945
    let out=ColorMath.appleLogTo709(SIMD3(grey,grey,grey))
    assert(abs(out.x-0.441)<0.01 && abs(out.x-out.z)<0.001,"Apple Log grey -> \(out)")
    assert(ColorMath.cubeFloats(size:5) { $0 }.count==5*5*5*4)
    let identity=ColorMath.cubeFloats(size:3) { $0 }
    assert(identity[4]==0.5 && identity[0]==0,"red varies fastest")
    assert(ColorMath.grade(SIMD3(0.5,0.5,0.5),[:])==SIMD3(0.5,0.5,0.5) || abs(ColorMath.grade(SIMD3(0.5,0.5,0.5),[:]).x-0.5)<0.001)
    // zoom: 16 Pro Max virtual camera (switch at 2 and 10) -> 0,5 1 2 5
    assert(ZoomMath.presets(base:2,switchOvers:[2,10],minDisplay:0.5,maxDisplay:25)==[0.5,1,2,5])
    assert(ZoomMath.presets(base:2,switchOvers:[2],minDisplay:0.5,maxDisplay:10)==[0.5,1,2])
    assert(abs(ZoomMath.rampRate(from:1,to:2,seconds:0.5)-2)<0.001)
    assert(ZoomMath.label(0.5)=="0,5×" && ZoomMath.label(5)=="5×")
    let c=Framing.crop(width:1080,height:1920,ratio:0.8)
    assert(c.w==1080 && abs(c.h-1350)<0.01)
    print("PASS actual profile selection: no resolution/FPS/HDR downgrade, supported slow-motion rates, fractional FPS and stabilization preference")
  }
}
