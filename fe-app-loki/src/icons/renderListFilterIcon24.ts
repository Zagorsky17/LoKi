import { svgEl } from '../helpers/svgEl';

export function renderListFilterIcon24() {
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
      class: 'lucide lucide-list-filter-icon lucide-list-filter',
    },
    [
      svgEl('path', { d: 'M3 6h18' }),
      svgEl('path', { d: 'M7 12h10' }),
      svgEl('path', { d: 'M10 18h4' }),
    ],
  );
}
