import std/[unittest, math]
import du_baobab/[dutree, rings]

let root = parseDu("30\tr/a\n10\tr/b\n40\tr\n")

suite "layoutRings":
  test "angles are proportional to size":
    let layout = layoutRings(root, 400, 400, maxDepth = 3)
    check layout.segments.len == 2
    check layout.segments[0].node.name == "a"
    check abs(layout.segments[0].endAngle - 1.5 * PI) < 1e-9
    check abs(layout.segments[1].endAngle - 2 * PI) < 1e-9

  test "hit testing":
    let layout = layoutRings(root, 400, 400, maxDepth = 3)
    check layout.hitTest(200, 200).kind == HitCenter
    let r = (layout.innerRadius(1) + layout.outerRadius(1)) / 2
    # Straight down (pi/2) is inside "a", straight up (3pi/2 + eps) in "b"
    let down = layout.hitTest(200, 200 + r)
    check down.kind == HitSegment
    check layout.segments[down.index].node.name == "a"
    let up = layout.hitTest(200 + 1, 200 - r)
    check up.kind == HitSegment
    check layout.segments[up.index].node.name == "b"
    check layout.hitTest(0, 0).kind == HitNone
