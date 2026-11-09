import { svgEl } from '../helpers/svgEl';

export function renderFileDownIcon24() {
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
      class: 'lucide lucide-file-down-icon lucide-file-down',
    },
    [
      svgEl('path', {
        d: 'M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z',
      }),
      svgEl('path', { d: 'M14 2v4a2 2 0 0 0 2 2h4' }),
      svgEl('path', { d: 'M12 18v-6' }),
      svgEl('path', { d: 'm9 15 3 3 3-3' }),
    ],
  );
}
