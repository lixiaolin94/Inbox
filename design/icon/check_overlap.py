import bpy, bmesh, sys, math
from mathutils.bvhtree import BVHTree
sys.argv = ["blender", "--", "--phase", "B"]
import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "build_icon.py")).read().split('if __name__ == "__main__":')[0])
p = dict(PARAMS)
build(p, phase="B")
frame = bpy.data.objects["FRAME_BODY"]
def overlaps(label):
    deps=bpy.context.evaluated_depsgraph_get(); me=frame.evaluated_get(deps).to_mesh()
    bm=bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
    tree=BVHTree.FromBMesh(bm, epsilon=0.0)
    ov=[(a,b) for a,b in tree.overlap(tree) if a<b and not (set(v.index for v in bm.faces[a].verts)&set(v.index for v in bm.faces[b].verts))]
    xs=[bm.faces[a].calc_center_median() for a,b in ov[:400]]
    zone=sum(1 for c in xs if abs(c.x)<2.3 and c.y<-3.0)
    print(f"{label}: faces {len(bm.faces)} overlaps {len(ov)}  (其中豁口区 {zone}/{min(len(ov),400)})")
overlaps("full")
pass
overlaps("no notch")
pass
frame.modifiers["Bevel"].show_viewport=False
overlaps("no bevel")
