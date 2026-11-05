import Home from '~/components/home/Home';
import { getClashAPIConfig, getSelectedChartStyleIndex } from '~/store/app';
import { connect } from '~/store/StateProvider';
import { State } from '~/store/types';

const mapState = (state: State) => ({
  apiConfig: getClashAPIConfig(state),
  selectedChartStyleIndex: getSelectedChartStyleIndex(state),
});

export default connect(mapState)(Home);
