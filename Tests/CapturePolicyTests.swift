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
    print("PASS actual profile selection: no resolution/FPS/HDR downgrade, supported slow-motion rates, fractional FPS and stabilization preference")
  }
}
