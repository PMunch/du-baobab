## Cairo rendering of a `RingLayout`.

import std/math
import owlkettle/cairo
import ./[dutree, rings, format]

proc cairo_arc_negative(ctx: CairoContext, x, y, r, a1, a2: cdouble) {.importc, cdecl.}

type Color = tuple[r, g, b: float]

proc hsv(h, s, v: float): Color =
  let
    i = int(floor(h * 6)) mod 6
    f = h * 6 - floor(h * 6)
    p = v * (1 - s)
    q = v * (1 - f * s)
    t = v * (1 - (1 - f) * s)
  case i
  of 0: (v, t, p)
  of 1: (q, v, p)
  of 2: (p, v, t)
  of 3: (p, q, v)
  of 4: (t, p, v)
  else: (v, p, q)

proc segmentColor(seg: Segment, highlighted: bool): Color =
  if seg.node.synthetic:
    result = (0.75, 0.75, 0.75)
  else:
    let hue = seg.midAngle / (2 * PI)
    result = hsv(hue, 0.85, max(0.45, 0.95 - 0.1 * float(seg.depth - 1)))
  if highlighted:
    result = (result.r * 0.5 + 0.5, result.g * 0.5 + 0.5, result.b * 0.5 + 0.5)

proc drawSegment(ctx: CairoContext, layout: RingLayout, seg: Segment) =
  let
    r0 = layout.innerRadius(seg.depth)
    r1 = layout.outerRadius(seg.depth)
  ctx.arc(layout.cx, layout.cy, r1, seg.startAngle, seg.endAngle)
  cairo_arc_negative(ctx, layout.cx, layout.cy, r0, seg.endAngle, seg.startAngle)
  ctx.closePath()

proc drawCenteredText(ctx: CairoContext, x, y: float, text: string) =
  let ext = ctx.textExtents(text)
  ctx.moveTo(x - ext.width / 2 - ext.xBearing, y - ext.height / 2 - ext.yBearing)
  ctx.text(text)
  ctx.fill()

proc drawShareBar*(ctx: CairoContext, width, height: float, fraction: float) =
  ## Small horizontal bar showing a share of the parent, as in Baobab's list.
  let y = height / 2 - 3
  ctx.rectangle(0, y, width, 6)
  ctx.source = (0.87, 0.87, 0.87)
  ctx.fill()
  ctx.rectangle(0, y, max(2.0, width * clamp(fraction, 0.0, 1.0)), 6)
  ctx.source = (0.21, 0.52, 0.89)
  ctx.fill()

proc drawRings*(ctx: CairoContext, layout: RingLayout, hovered: DuNode = nil) =
  ctx.lineWidth = 1.0
  for seg in layout.segments:
    ctx.drawSegment(layout, seg)
    ctx.source = segmentColor(seg, seg.node == hovered)
    ctx.fillPreserve()
    ctx.source = (1.0, 1.0, 1.0)
    ctx.stroke()

  # Centre circle with the name and size of the hovered (or current) node
  ctx.circle(layout.cx, layout.cy, layout.centerRadius)
  ctx.source = (if hovered == layout.root: (0.9, 0.9, 0.9) else: (1.0, 1.0, 1.0))
  ctx.fill()

  let shown = if hovered.isNil: layout.root else: hovered
  ctx.source = (0.2, 0.2, 0.2)
  ctx.fontSize = 13.0
  if shown != layout.root:
    ctx.drawCenteredText(layout.cx, layout.cy - 9, shown.name)
    ctx.drawCenteredText(layout.cx, layout.cy + 9, formatSize(shown.size))
  else:
    ctx.drawCenteredText(layout.cx, layout.cy, formatSize(shown.size))
