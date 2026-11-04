// The Sections and Servers tables share a grid; these two widths decide whether the columns
// line up across the tabs. The kind column fits the widest value, Shadowsocks.
export const GRID_SWITCH_COLUMN_WIDTH = '6rem';

export const GRID_KIND_COLUMN_WIDTH = '8rem';

// LuCI's catalog translates "Edit" as "Редактировать", too long for a table cell, so a Loki
// msgid carries the short word; the English text is written out for when the msgid comes back
// untranslated.
export function getRuleEditButtonText() {
  const label = _('Edit rule action');

  return label === 'Edit rule action' ? 'Edit' : label;
}

// Loads only the table's columns; modalonly options load when the dialog opens.
export function loadVisibleTableOptions(sectionRef: CBISection) {
  const tasks: Promise<unknown>[] = [];

  sectionRef.cfgsections().forEach((sectionId: string) => {
    sectionRef.children.forEach((option) => {
      if (option.disable || option.modalonly) {
        return;
      }

      tasks.push(
        Promise.resolve(option.load.call(option, sectionId)).then(
          (value: unknown) => {
            option.cfgvalue(sectionId, value);
          },
        ),
      );
    });
  });

  return Promise.all(tasks);
}
