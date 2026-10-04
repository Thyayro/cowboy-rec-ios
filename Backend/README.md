# Native capture integration

ARKit is a separate capture mode. The grid is preview-only. Accepted encoder frames carry relative video timestamps, column-major camera-to-world transforms in meters, intrinsics and tracking quality. The VPS exposes JSON and a Blender Python import through the existing owner-protected library. Limited tracking is excluded from Blender keyframes. AR format comes from ARKit and is displayed, not advertised as cinematic 4K/60.

Apple Log is enabled only when the selected AVFoundation format supports it. The native queue requests Rec.709 conversion with `keep`, preserving original media. Upload starts after stopping capture; this is not live cloud streaming. Preview does not apply a Log LUT.

`rec-ar.patch` targets the production backend baseline. `ar-tracking.js` lives next to `server/rec.js`. API integration tests exercised retries, invalid JSON preservation, exports and owner isolation on temporary data. A synthetic FFmpeg test exercised declared Apple Log conversion, unchanged original hash, resolution, 60fps and audio. Physical iPhone calibration and tracking remain to be tested.
