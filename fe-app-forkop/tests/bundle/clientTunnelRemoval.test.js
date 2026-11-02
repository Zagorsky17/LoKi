import { describe, expect, it } from 'vitest';
import { createHarness } from '../lib/luciForm.js';
import { coreFeatures } from '../lib/coreFeatures.js';

describe('the page without built-in VPN tunnels', () => {
  it.each([[], ['with_wireguard', 'with_tailscale', 'with_openconnect']])(
    'offers remaining connections without restoring tunnels for core tags %j',
    (add) => {
      const harness = createHarness();
      harness.bundle.setCoreFeatures(coreFeatures({ add }));
      harness.uci.add('forkop', 'section', 'sec');
      Object.assign(harness.store.get('sec'), {
        action: 'connection',
        enabled: '1',
      });
      harness.uci.add('forkop', 'tunnel', 'retired');
      Object.assign(harness.store.get('retired'), {
        section: 'sec',
        kind: 'tailscale',
        name: 'Retired',
        tailscale_auth_key: 'synthetic-auth-key',
      });
      const map = new harness.form.Map('forkop');
      const grid = map.section(harness.form.GridSection, 'section');
      harness.bundle.createSectionContent(grid);
      const names = grid.children.map((option) => option.option);
      expect(names).not.toContain('tunnels');
      for (const name of [
        'connection_link',
        'subscription_url',
        'interfaces',
        'outbound_jsons',
        'urltest',
        'fallback_group',
      ]) {
        expect(names).toContain(name);
      }
      const settings = map.section(harness.form.TypedSection, 'settings');
      harness.bundle.createSettingsContent(settings);
      const settingsNames = settings.children.map((option) => option.option);
      expect(settingsNames).not.toContain('warp_profiles_via_proxy');
      expect(settingsNames).not.toContain('warp_profiles_via_proxy_section');
      expect(harness.operations).not.toContainEqual(
        expect.objectContaining({ command: 'generate_warp_profile' }),
      );
    },
  );
});
