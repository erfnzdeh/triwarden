type Box = Pick<DOMRect, 'left' | 'right' | 'top' | 'height'>;

/** Position the field icon inside a normal field, or just beyond a row of one-character code fields. */
export function iconPosition(box: Box, rtl: boolean, outside: boolean) {
  const left = outside ? (rtl ? box.left - 28 : box.right + 6) : rtl ? box.left + 8 : box.right - 30;
  return { display: 'grid', left: `${left}px`, top: `${box.top + (box.height - 22) / 2}px` };
}

/** Align the menu with the field's writing start while keeping it inside the viewport. */
export function menuLeft(box: Pick<Box, 'left' | 'right'>, width: number, rtl: boolean, viewportWidth: number) {
  const start = rtl ? box.right - width : box.left;
  return `${Math.max(8, Math.min(start, viewportWidth - width - 8))}px`;
}
