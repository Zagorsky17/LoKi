import { svgEl } from '../helpers/svgEl';

export function renderGlobeIcon24() {
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
      class: 'lucide lucide-globe-icon lucide-globe',
    },
    [
      svgEl('circle', {
        cx: '12',
        cy: '12',
        r: '10',
      }),
      svgEl('path', {
        d: 'M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20',
      }),
      svgEl('path', {
        d: 'M2 12h20',
      }),
    ],
  );
}
