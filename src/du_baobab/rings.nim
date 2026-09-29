## Geometry of the rings (sunburst) chart, independent of any drawing API.
##
## The current directory is the centre circle. Each ring outwards is one
## level deeper; a child's angular extent is proportional to its share of
## the parent's size. Angles are in radians, clockwise from the positive
## x-axis (cairo's convention on a y-down surface).

import std/math
import ./dutree

type
  Segment* = object
    node*: DuNode
    depth*: int            ## 1 = innermost ring
    startAngle*, endAngle*: float

  RingLayout* = object
    cx*, cy*: float
    centerRadius*: float   ## Radius of the centre circle
    ringWidth*: float
    maxDepth*: int
    root*: DuNode
    segments*: seq[Segment]

  HitKind* = enum
    HitNone, HitCenter, HitSegment

  Hit* = object
    case kind*: HitKind
    of HitSegment:
      index*: int
    else: discard

proc innerRadius*(layout: RingLayout, depth: int): float =
  layout.centerRadius + float(depth - 1) * layout.ringWidth

proc outerRadius*(layout: RingLayout, depth: int): float =
  layout.innerRadius(depth) + layout.ringWidth

proc midAngle*(seg: Segment): float =
  (seg.startAngle + seg.endAngle) / 2

proc layoutRings*(root: DuNode, width, height: float,
                  maxDepth = 5, minAngle = 0.005, margin = 16.0): RingLayout =
  ## Computes ring segments for `root`. Segments narrower than `minAngle`
  ## are omitted (together with their descendants).
  let maxRadius = max(0.0, min(width, height) / 2 - margin)
  result = RingLayout(
    cx: width / 2, cy: height / 2,
    maxDepth: maxDepth, root: root,
    # The centre circle is 1.5x as wide as a ring.
    ringWidth: maxRadius / (float(maxDepth) + 1.5)
  )
  result.centerRadius = result.ringWidth * 1.5

  proc visit(layout: var RingLayout, node: DuNode, depth: int,
             startAngle, span: float) =
    if depth > layout.maxDepth or node.size <= 0:
      return
    var angle = startAngle
    for child in node.children:
      let childSpan = span * child.size.float / node.size.float
      if childSpan >= minAngle:
        layout.segments.add Segment(node: child, depth: depth,
          startAngle: angle, endAngle: angle + childSpan)
        layout.visit(child, depth + 1, angle, childSpan)
      angle += childSpan

  result.visit(root, 1, 0.0, 2 * PI)

proc hitTest*(layout: RingLayout, x, y: float): Hit =
  let
    dx = x - layout.cx
    dy = y - layout.cy
    r = hypot(dx, dy)
  if r <= layout.centerRadius:
    return Hit(kind: HitCenter)
  if layout.ringWidth <= 0:
    return Hit(kind: HitNone)
  let depth = int(floor((r - layout.centerRadius) / layout.ringWidth)) + 1
  var angle = arctan2(dy, dx)
  if angle < 0:
    angle += 2 * PI
  for i, seg in layout.segments:
    if seg.depth == depth and angle >= seg.startAngle and angle < seg.endAngle:
      return Hit(kind: HitSegment, index: i)
  Hit(kind: HitNone)
