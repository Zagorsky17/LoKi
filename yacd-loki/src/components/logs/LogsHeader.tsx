import { useTranslation } from 'react-i18next';

import { Pause, Play, Trash2 } from '~/components/shared/FeatherIcons';
import {
  HeaderActions,
  HeaderButton,
  HeaderRowBreak,
  HeaderSearch,
  headerSearchInlineClass,
  headerSelectClass,
  HeaderTitle,
  PageHeader,
} from '~/components/shared/PageHeader';
import Select from '~/components/shared/Select';
import { TextFilter } from '~/components/shared/TextFilter';
import { LOG_LEVEL_OPTIONS } from '~/modules/config/utils';
import { logFilterText } from '~/store/logs';

import s from './LogsHeader.module.scss';

type Props = {
  logLevel: string;
  setLogLevel: (level: string) => void;
  isPaused: boolean;
  toggleIsPaused: () => void;
  onClear: () => void;
};

export function LogsHeader({ logLevel, setLogLevel, isPaused, toggleIsPaused, onClear }: Props) {
  const { t } = useTranslation();

  return (
    <PageHeader>
      <HeaderTitle>{t('Logs')}</HeaderTitle>

      <Select
        options={LOG_LEVEL_OPTIONS}
        selected={logLevel ? logLevel.toLowerCase() : 'info'}
        className={`${headerSelectClass} ${s.levelSelect}`}
        aria-label={t('log_level')}
        onChange={(e) => setLogLevel(e.target.value)}
      />

      <HeaderSearch className={`${headerSearchInlineClass} ${s.search}`}>
        <TextFilter textAtom={logFilterText} placeholder={t('search_logs_placeholder')} />
      </HeaderSearch>

      <HeaderActions className={s.actions}>
        <HeaderButton
          variant={isPaused ? 'paused' : 'ghost'}
          icon={isPaused ? <Play size={14} /> : <Pause size={14} />}
          label={isPaused ? t('Resume Refresh') : t('Pause Refresh')}
          onClick={toggleIsPaused}
        />
        <HeaderButton
          variant="danger"
          icon={<Trash2 size={14} />}
          label={t('Clear')}
          onClick={onClear}
        />
      </HeaderActions>

      {/* 窄屏下强制换行，让级别筛选和搜索独占第二行 */}
      <HeaderRowBreak className={s.rowBreak} />
    </PageHeader>
  );
}
