import { svgEl } from '../helpers/svgEl';

export function renderFileUpIcon24() {
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
      class: 'lucide lucide-file-up-icon lucide-file-up',
    },
    [
      svgEl('path', {
        d: 'M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z',
      }),
      svgEl('path', { d: 'M14 2v4a2 2 0 0 0 2 2h4' }),
      svgEl('path', { d: 'M12 12v6' }),
      svgEl('path', { d: 'm15 15-3-3-3 3' }),
    ],
  );
}
