import { describe, expect, it, vi } from 'vitest';
import { resolveOutboundProxyLink } from '../resolveOutboundProxyLink';

const outbound = {
  code: 'subscription-provider/Node',
  displayName: 'Node',
  latency: 0,
  type: 'VLESS',
  selected: false,
};

describe('resolveOutboundProxyLink', () => {
  it('copies a configured connection URL without querying sing-box', async () => {
    const fetchProxyLink = vi.fn();
    const link = 'vless://id@example.com:443#Manual';

    await expect(
      resolveOutboundProxyLink({ ...outbound, link }, fetchProxyLink),
    ).resolves.toBe(link);
    expect(fetchProxyLink).not.toHaveBeenCalled();
  });

  it('loads a provider link only on demand', async () => {
    const fetchProxyLink = vi.fn().mockResolvedValue({
      success: true,
      data: { url: 'trojan://secret@example.com:443#Provider' },
    });

    await expect(
      resolveOutboundProxyLink(
        { ...outbound, canCopyLink: true },
        fetchProxyLink,
      ),
    ).resolves.toBe('trojan://secret@example.com:443#Provider');
    expect(fetchProxyLink).toHaveBeenCalledWith(outbound.code);
  });

  it('rejects an unexpected URI returned by the runtime endpoint', async () => {
    const fetchProxyLink = vi.fn().mockResolvedValue({
      success: true,
      data: { url: 'javascript:alert(1)' },
    });

    await expect(
      resolveOutboundProxyLink(
        { ...outbound, canCopyLink: true },
        fetchProxyLink,
      ),
    ).resolves.toBe('');
  });
});
