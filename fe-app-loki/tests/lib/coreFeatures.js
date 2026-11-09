// The base build's report is core_report_base in tests/fixtures/page_contract.json; other
// builds are that report with tags changed.
import fs from 'fs';
import path from 'path';

import { ROOT } from './paths.js';

function contract() {
  return JSON.parse(
    fs.readFileSync(
      path.join(ROOT, 'tests/fixtures/page_contract.json'),
      'utf8',
    ),
  );
}

export function coreFeatures({ add = [], remove = [] } = {}) {
  const report = contract().core_report_base;
  report.tags = [...report.tags.filter((tag) => !remove.includes(tag)), ...add];
  for (const entry of Object.values(report.features)) {
    entry.available = entry.tags.every((tag) => report.tags.includes(tag));
  }
  return report;
}

export function linkFeatureCases() {
  return contract().link_features;
}
