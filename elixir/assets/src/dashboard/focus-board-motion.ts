export type FocusEjectOffset = { opacity: number; x: number; y: number };
export type FocusEjectRect = { id: string; left: number; top: number; width: number; height: number };

export function focusAttachOffset(rects: FocusEjectRect[], selectedId: string) {
  const selected = rects.find((rect) => rect.id === selectedId);
  if (!selected) return 0;
  const selectedBottom = selected.top + selected.height;
  const sameRow = rects.filter((rect) => rect.top + rect.height > selected.top + 1 && rect.top < selectedBottom - 1);
  return Math.max(0, Math.round(Math.max(...sameRow.map((rect) => rect.top + rect.height)) - selectedBottom));
}

export function focusTravelScale(expandedHeight: number, viewportHeight: number) {
  return Math.min(1, Math.max(0.35, expandedHeight / Math.max(1, viewportHeight * 0.8)));
}

export function focusSectionOffset(sectionTop: number, viewportHeight: number, travelScale = 1) {
  return Math.round(Math.max(0, viewportHeight - sectionTop + 48) * travelScale);
}

export function focusSpaceOffsets(rects: FocusEjectRect[], selectedId: string, viewport: { height: number; width: number }, focusLeft: number, travelScale = 1) {
  const selected = rects.find((rect) => rect.id === selectedId);
  if (!selected) return new Map<string, FocusEjectOffset>();
  const selectedBottom = selected.top + selected.height;
  const selectedCenter = selected.left + selected.width / 2;
  const below = rects.filter((rect) => rect.id !== selectedId && rect.top >= selectedBottom - 1);
  const sameRow = rects.filter((rect) => rect.id !== selectedId && rect.top + rect.height > selected.top + 1 && rect.top < selectedBottom - 1);
  const left = sameRow.filter((rect) => rect.left + rect.width / 2 < selectedCenter);
  const right = sameRow.filter((rect) => rect.left + rect.width / 2 >= selectedCenter);
  const leftX = left.length ? 0 - Math.max(...left.map((rect) => rect.left + rect.width)) - 48 : 0;
  const rightX = right.length ? viewport.width - Math.min(...right.map((rect) => rect.left)) + 48 : 0;
  const bottomY = below.length ? Math.max(0, viewport.height - Math.min(...below.map((rect) => rect.top)) + 48) : 0;

  return new Map(rects.map((rect) => {
    if (rect.id === selectedId) return [rect.id, { opacity: 1, x: Math.round(focusLeft - rect.left), y: 0 }];
    if (rect.top + rect.height <= selected.top + 1) return [rect.id, { opacity: 1, x: 0, y: 0 }];
    if (rect.top >= selectedBottom - 1) {
      if (rect.top >= viewport.height + 48) return [rect.id, { opacity: 1, x: 0, y: 0 }];
      const y = Math.round(bottomY * travelScale);
      return [rect.id, { opacity: y > 0 ? 0 : 1, x: 0, y }];
    }
    const horizontalExit = rect.left + rect.width / 2 < selectedCenter ? leftX : rightX;
    return [rect.id, { opacity: 0, x: Math.round(horizontalExit * travelScale), y: 0 }];
  }));
}
