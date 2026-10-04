'use strict';
function validate(doc){
 if(!doc||doc.schema!=='cowboy-arkit/v1'||!Number.isInteger(doc.width)||!Number.isInteger(doc.height)||doc.width<16||doc.width>8192||doc.height<16||doc.height>8192||!Number.isFinite(doc.fps)||doc.fps<1||doc.fps>240||!Array.isArray(doc.frames)||!doc.frames.length||doc.frames.length>25000)throw Error('dados AR inválidos');
 let last=-1;
 for(const f of doc.frames){
  if(!Number.isFinite(f.t)||f.t<0||f.t<=last||f.t>86400)throw Error('tempo AR inválido');last=f.t;
  if(!Array.isArray(f.transform)||f.transform.length!==16||!f.transform.every(v=>Number.isFinite(v)&&Math.abs(v)<1e6))throw Error('pose AR inválida');
  if(![3,7,11].every(i=>Math.abs(f.transform[i])<.001)||Math.abs(f.transform[15]-1)>.001)throw Error('matriz AR não afim');
  if(!Array.isArray(f.intrinsics)||f.intrinsics.length!==9||!f.intrinsics.every(v=>Number.isFinite(v)&&Math.abs(v)<100000)||f.intrinsics[0]<=0||f.intrinsics[4]<=0)throw Error('calibração AR inválida');
  if(typeof f.tracking!=='string'||f.tracking.length>120)throw Error('qualidade AR inválida');
 }
 return doc;
}
function blender(doc,filename){
 validate(doc);
 return `# Cowboy ARKit: poses reais, metros, vídeo bruto sem grade/estabilização digital.
# Quadros com rastreamento limitado não recebem keyframes válidos.
import bpy, json, math, os
from mathutils import Matrix
DATA=json.loads(${JSON.stringify(JSON.stringify(doc))})
scene=bpy.context.scene
scene.render.fps=round(DATA['fps']); scene.render.fps_base=round(DATA['fps'])/DATA['fps']
scene.render.resolution_x=DATA['width'];scene.render.resolution_y=DATA['height'];scene.render.resolution_percentage=100
camera_data=bpy.data.cameras.new('Cowboy_ARKit'); camera=bpy.data.objects.new('Cowboy_ARKit',camera_data)
scene.collection.objects.link(camera);scene.camera=camera;camera.rotation_mode='QUATERNION';camera_data.sensor_fit='HORIZONTAL';camera_data.sensor_width=36
C=Matrix(((1,0,0,0),(0,0,-1,0),(0,1,0,0),(0,0,0,1)))
previous=None;valid=0
for sample in DATA['frames']:
    if sample['tracking']!='normal': continue
    m=sample['transform'];T=Matrix(tuple(tuple(m[col*4+row] for col in range(4)) for row in range(4)))
    world=C @ T;frame=round(sample['t']*DATA['fps'])+1
    camera.location=world.to_translation();q=world.to_quaternion()
    if previous is not None: q.make_compatible(previous)
    previous=q;camera.rotation_quaternion=q
    camera.keyframe_insert('location',frame=frame);camera.keyframe_insert('rotation_quaternion',frame=frame)
    k=sample['intrinsics'];camera_data.lens=k[0]*36/DATA['width']
    camera_data.shift_x=(DATA['width']/2-k[6])/DATA['width'];camera_data.shift_y=(k[7]-DATA['height']/2)/DATA['width']
    camera_data.keyframe_insert('lens',frame=frame);camera_data.keyframe_insert('shift_x',frame=frame);camera_data.keyframe_insert('shift_y',frame=frame);valid+=1
if not valid: raise RuntimeError('Sem quadros com rastreamento AR normal')
scene.frame_start=1;scene.frame_end=round(DATA['frames'][-1]['t']*DATA['fps'])+1
if DATA.get('floor_origin_selected'):
    mesh=bpy.data.meshes.new('Chao_ARKit');mesh.from_pydata([(-10,-10,0),(10,-10,0),(10,10,0),(-10,10,0)],[],[(0,1,2,3)])
    floor=bpy.data.objects.new('Chao_ARKit',mesh);scene.collection.objects.link(floor);floor.display_type='WIRE'
movie=bpy.path.abspath('//'+${JSON.stringify(filename)})
if os.path.exists(movie):
    clip=bpy.data.movieclips.load(movie);camera_data.show_background_images=True
    background=camera_data.background_images.new();background.source='MOVIE_CLIP';background.clip=clip;background.alpha=1.0
print('Cowboy ARKit: camera criada; abra o vídeo '+${JSON.stringify(filename)}+' como fundo. Poses AR são estimativas, não substituem verificação do alinhamento.')
`;
}
module.exports={validate,blender};
