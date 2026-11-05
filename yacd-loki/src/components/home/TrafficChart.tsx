import * as React from 'react';
import { Line } from 'react-chartjs-2';

import { chartJSResource, chartStyles, commonDataSetProps } from '~/misc/chart';
import { CHART_WINDOW, useScrollingChart } from '~/modules/home/hooks';
import { formatTrafficRate, gradientFill, peakOf } from '~/modules/home/utils';

const { useMemo, useRef } = React;

/** 多画几个窗口外的点，左边缘的线段才不会在数据滚动时被截断 */
const OVERSCAN = 3;

/** 纵轴最小量程，空闲时不至于把噪声放大成大起大落 */
const Y_FLOOR = 100 * 1024;

/**
 * 速率跨度可以从几百 B/s 到几十 MB/s，直接画会被尖峰压成一条贴底的直线。
 * 用 log1p 压缩后再画（0 仍然映射到 0），读数时用 expm1 还原。
 */
const compress = (v: number) => Math.log1p(v);
const decompress = (v: number) => Math.expm1(v);

type Traffic = { up: number[]; down: number[]; labels: number[] };

type Props = {
  traffic: Traffic;
  styleIndex: number;
  downLabel: string;
  upLabel: string;
};

const options: any = {
  responsive: true,
  maintainAspectRatio: false,
  parsing: false,
  // 曲线的移动完全交给 useScrollingChart 逐帧推进坐标轴，元素本身不做补间
  animation: false,
  interaction: {
    mode: 'index',
    intersect: false,
  },
  plugins: {
    legend: { display: false },
    tooltip: {
      enabled: true,
      callbacks: {
        title: (items: any[]) => new Date(items[0].parsed.x).toLocaleTimeString(),
        // 画的是压缩后的值，提示里要还原成真实速率
        label: (ctx: any) =>
          ` ${ctx.dataset.label}  ${formatTrafficRate(decompress(ctx.parsed.y))}`,
      },
    },
  },
  scales: {
    // x 的窗口、y 的量程都由动画帧逐帧写入
    x: { type: 'time', display: false },
    y: {
      display: true,
      border: { display: false },
      grid: {
        color: 'rgba(148, 163, 184, 0.22)',
        drawTicks: false,
      },
      // 固定 5 条刻度，网格线始终落在同样的像素高度，量程变化时不会跳动
      ticks: { display: false, count: 5 },
    },
  },
  elements: {
    // monotone 插值：曲线平滑但不会在两点之间过冲到负值，面积图不会出现假的凹陷
    line: { borderWidth: 2, cubicInterpolationMode: 'monotone' },
    point: { radius: 0, hitRadius: 10, hoverRadius: 4 },
  },
};

export default function TrafficChart({ traffic, styleIndex, downLabel, upLabel }: Props) {
  chartJSResource.read();

  const chartRef = useRef<any>(null);
  const size = CHART_WINDOW + OVERSCAN;

  useScrollingChart(chartRef, () => ({
    min: 0,
    max: compress(Math.max(peakOf(traffic.up, size), peakOf(traffic.down, size), Y_FLOOR)) * 1.15,
  }));

  const style = chartStyles[styleIndex] || chartStyles[0];

  const data = useMemo(() => {
    const labels = traffic.labels.slice(-size);
    const toPoints = (values: number[]) =>
      values.slice(-size).map((y, i) => ({ x: labels[i], y: y === null ? null : compress(y) }));

    return {
      datasets: [
        {
          ...commonDataSetProps,
          borderWidth: 2,
          label: downLabel,
          borderColor: style.down.borderColor,
          backgroundColor: gradientFill(style.down.borderColor),
          data: toPoints(traffic.down),
          fill: true,
        },
        {
          ...commonDataSetProps,
          borderWidth: 2,
          label: upLabel,
          borderColor: style.up.borderColor,
          backgroundColor: gradientFill(style.up.borderColor),
          data: toPoints(traffic.up),
          fill: true,
        },
      ],
    };
  }, [traffic, size, style, downLabel, upLabel]);

  return <Line ref={chartRef} data={data} options={options} redraw={false} />;
}
