import Rules from '~/components/rules/Rules';
import { getClashAPIConfig } from '~/store/app';
import { connect } from '~/store/StateProvider';
import { State } from '~/store/types';

const mapState = (state: State) => ({
  apiConfig: getClashAPIConfig(state),
});

export default connect(mapState)(Rules);
