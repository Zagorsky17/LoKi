import { Loki } from '../../types';

// The selector sweeping its members, or the one outbound of a section without a choice.
export function sectionLatencyTarget(
  section: Loki.OutboundGroup,
): { type: 'group' | 'proxy'; tag: string } | undefined {
  if (section.withTagSelect) {
    return { type: 'group', tag: section.code };
  }

  const outbound = section.outbounds[0];
  return outbound ? { type: 'proxy', tag: outbound.code } : undefined;
}
