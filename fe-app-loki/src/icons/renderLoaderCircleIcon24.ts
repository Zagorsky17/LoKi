import { spinPhaseStyle } from '../helpers/spinPhase';
import { svgEl } from '../helpers/svgEl';

export function renderLoaderCircleIcon24() {
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
      class: 'lucide lucide-loader-circle rotate',
      // Where in the .rotate turn this spinner starts, so a replacement picks up where its predecessor was.
      style: spinPhaseStyle(),
    },
    [
      svgEl('path', {
        d: 'M21 12a9 9 0 1 1-6.219-8.56',
      }),
    ],
  );
}
