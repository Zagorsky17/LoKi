import { svgEl } from '../helpers/svgEl';

export function renderSquareTerminalIcon24() {
  const NS = 'http://www.w3.org/2000/svg';
  return svgEl(
    'svg',
    {
      xmlns: NS,
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      class: 'lucide lucide-square-terminal-icon lucide-square-terminal',
    },
    [
      svgEl('path', { d: 'm7 11 2-2-2-2' }),
      svgEl('path', { d: 'M11 13h4' }),
      svgEl('rect', {
        width: '18',
        height: '18',
        x: '3',
        y: '3',
        rx: '2',
        ry: '2',
      }),
    ],
  );
}
