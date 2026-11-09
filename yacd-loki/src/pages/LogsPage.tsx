import Logs from '~/components/logs/Logs';
import { getClashAPIConfig, getLogStreamingPaused } from '~/store/app';
import { getLogLevel } from '~/store/configs';
import { connect } from '~/store/StateProvider';
import { State } from '~/store/types';

const mapState = (state: State) => ({
  logLevel: getLogLevel(state),
  apiConfig: getClashAPIConfig(state),
  logStreamingPaused: getLogStreamingPaused(state),
});

export default connect(mapState)(Logs);
