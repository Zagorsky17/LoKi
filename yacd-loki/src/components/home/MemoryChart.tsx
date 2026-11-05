import * as React from 'react';
import { Line } from 'react-chartjs-2';

import { chartJSResource, chartStyles, commonDataSetProps } from '~/misc/chart';
import prettyBytes from '~/misc/pretty-bytes';
import { CHART_WINDOW, useScrollingChart } from '~/modules/home/hooks';
import { gradientFill, rangeOf } from '~/modules/home/utils';

const { useMemo, useRef } = React;

/** 多画几个窗口外的点，左边缘的线段才不会在数据滚动时被截断 */
const OVERSCAN = 3;

/** 内存读数很平稳，量程上下各留 2% 的余量，免得细微波动被放大成剧烈起伏 */
const PAD_RATIO = 0.02;

type Memory = { inuse: number[]; labels: number[] };

type Props = {
  memory: Memory;
  styleIndex: number;
};

const options: any = {
  responsive: true,
  maintainAspectRatio: false,
  parsing: false,
  animation: false,
  interaction: {
    mode: 'index',
    intersect: false,
  },
  plugins: {
    legend: { display: false },
    tooltip: {
      enabled: true,
      displayColors: false,
      callbacks: {
        title: (items: any[]) => new Date(items[0].parsed.x).toLocaleTimeString(),
        label: (ctx: any) => ` ${prettyBytes(ctx.parsed.y)}`,
      },
    },
  },
  scales: {
    // x 的窗口、y 的量程都由动画帧逐帧写入
    x: { type: 'time', display: false },
    y: { display: false },
  },
  elements: {
    line: { borderWidth: 2, cubicInterpolationMode: 'monotone' },
    point: { radius: 0, hitRadius: 10, hoverRadius: 4 },
  },
};

export default function MemoryChart({ memory, styleIndex }: Props) {
  chartJSResource.read();

  const chartRef = useRef<any>(null);
  const size = CHART_WINDOW + OVERSCAN;

  // 内存不是从 0 开始的量，量程跟着数据区间走，否则曲线会被压成贴顶的一条直线
  useScrollingChart(chartRef, () => rangeOf(memory.inuse, size, PAD_RATIO));

  const style = chartStyles[styleIndex] || chartStyles[0];

  const data = useMemo(() => {
    const labels = memory.labels.slice(-size);
    return {
      datasets: [
        {
          ...commonDataSetProps,
          borderWidth: 2,
          borderColor: style.inuse.borderColor,
          backgroundColor: gradientFill(style.inuse.borderColor),
          // 内核推送的首帧是 0，和缓冲里未填充的 null 一样当作没有数据
          data: memory.inuse.slice(-size).map((y, i) => ({ x: labels[i], y: y > 0 ? y : null })),
          fill: true,
        },
      ],
    };
  }, [memory, size, style]);

  return <Line ref={chartRef} data={data} options={options} redraw={false} />;
}
