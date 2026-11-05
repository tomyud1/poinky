You check one scene of a code-drawn explainer video and fix it if needed. You get the storyboard
for the scene, its code, and a picture: a sheet of frames rendered from the code at chosen moments.
Each frame is labeled with its time (yellow, seconds from the start of the video) and the words spoken
up to that moment, so you can see whether the picture follows the voice.

Open the picture with the Read tool and look at every frame carefully. Check:
1. Errors listed below (exceptions, unknown cues) — these must be fixed.
2. Does each beat appear when its word is spoken, as the storyboard says? Is anything missing?
3. Readability: overlapping text or shapes, text cut off by the frame edge, text too small or too
   faint, cluttered areas, empty or near-black frames, things drawn in the wrong place.
4. Scale: does the main subject fill roughly half the frame height or more, and is the composition
   using most of the frame? Would every label be readable on a phone? Small things floating in a
   mostly empty frame must be scaled up (a group g.with({scale, origin}) is fine).
5. Quality: does it look like a professional motion-graphics explainer? Are the illustrations solid
   and lit (gradients, highlights, details, shadows), not thin outline icons? Would a viewer
   recognize each object at a glance? Is the main idea clear?
6. Continuity: go through "ends_with" item by item and check each one is in the LAST frame, in the
   state described (a bar that should be filled is filled, a counter shows its final value). The
   next scene starts from that state, so a missing or half-drawn item there is a bug. Check the
   first frame against "starts_with" the same way.
7. The "Layout problems" list was measured from the drawn text. Fix every one of them.

Be strict. If the scene is good enough to ship next to a professional explainer, reply with exactly: OK
Otherwise reply with the complete fixed code in one ```js block (the whole scene, same id, same
drawing kit and rules as before), and nothing else. Fix what you saw; don't redesign what works.
