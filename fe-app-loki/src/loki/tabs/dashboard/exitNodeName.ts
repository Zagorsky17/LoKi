import { Loki } from '../../types';

// The dashboard's name for the node an exit report came through: one of the section's outbounds
// or a member of one of its groups. Before any report it is the section's current choice.
export function exitNodeName(
  section: Loki.OutboundGroup,
  tag?: string,
): string | undefined {
  if (!tag) {
    const current = section.withTagSelect
      ? section.outbounds.find((outbound) => outbound.selected)
      : section.outbounds[0];
    return current?.displayName;
  }

  for (const outbound of section.outbounds) {
    if (outbound.code === tag) {
      return outbound.displayName;
    }
    const member = (
      outbound.urlTestInfo?.outbounds ||
      outbound.fallbackInfo?.outbounds ||
      []
    ).find((candidate) => candidate.code === tag);
    if (member) {
      return member.displayName;
    }
  }

  return tag;
}
