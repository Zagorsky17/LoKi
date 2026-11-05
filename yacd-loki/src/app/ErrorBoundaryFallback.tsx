import SvgGithub from '~/components/shared/SvgGithub';
import SvgYacd from '~/components/shared/SvgYacd';

import s0 from './ErrorBoundaryFallback.module.scss';

const yacdRepoIssueUrl = 'https://github.com/metacubex/yacd';

type Props = {
  message?: string;
  detail?: string;
};

function ErrorBoundaryFallback({ message, detail }: Props) {
  return (
    <div className={s0.root}>
      <div className={s0.yacd}>
        <SvgYacd width={150} height={150} />
      </div>
      {message ? <h1>{message}</h1> : null}
      {detail ? <p>{detail}</p> : null}
      <p>
        <a className={s0.link} href={yacdRepoIssueUrl}>
          <SvgGithub width={16} height={16} />
          metacubex/yacd
        </a>
      </p>
    </div>
  );
}

export default ErrorBoundaryFallback;
