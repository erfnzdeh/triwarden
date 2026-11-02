import { describe, expect, it } from 'vitest';
import { iconPosition, menuLeft } from './overlay-layout';

const field = { left: 100, right: 300, top: 40, height: 42 } as DOMRect;

describe('overlay placement', () => {
  it('mirrors the icon inside right-to-left fields', () => {
    expect(iconPosition(field, false, false)).toMatchObject({ left: '270px', top: '50px' });
    expect(iconPosition(field, true, false)).toMatchObject({ left: '108px', top: '50px' });
  });

  it('puts the icon beyond the visual end of a one-time-code row', () => {
    expect(iconPosition(field, false, true).left).toBe('306px');
    expect(iconPosition(field, true, true).left).toBe('72px');
  });

  it('aligns the menu to the field start in either direction', () => {
    const wideField = { left: 500, right: 800 };
    expect(menuLeft(wideField, 332, false, 1440)).toBe('500px');
    expect(menuLeft(wideField, 332, true, 1440)).toBe('468px');
  });

  it('keeps the menu inside the viewport', () => {
    expect(menuLeft({ left: -20, right: 100 }, 332, false, 800)).toBe('8px');
    expect(menuLeft({ left: 700, right: 900 }, 332, true, 800)).toBe('460px');
  });
});
