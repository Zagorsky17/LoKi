import React from 'react';

import Button from '~/components/shared/Button';
import { Zap } from '~/components/shared/FeatherIcons';
import Input from '~/components/shared/Input';
import Loading from '~/components/shared/Loading';
import SwitchThemed from '~/components/shared/SwitchThemed';
import ToggleSwitch from '~/components/shared/ToggleSwitch';

const noop = () => {
  /* empty */
};

const paneStyle = {
  padding: '20px 0',
};

const optionsRule = [
  { label: 'Global', value: 'Global' },
  { label: 'Rule', value: 'Rule' },
  { label: 'Direct', value: 'Direct' },
];

type PaneProps = {
  children: React.ReactNode;
  style?: React.CSSProperties;
};

const Pane = ({ children, style }: PaneProps) => (
  <div style={{ ...paneStyle, ...style }}>{children}</div>
);

function useToggle(initialState = false) {
  const [onoff, setonoff] = React.useState(initialState);
  const handleChange = React.useCallback(() => {
    setonoff((x) => !x);
  }, []);
  return [onoff, handleChange] as const;
}

function SwitchExample() {
  const [checked, handleChange] = useToggle(false);
  return <SwitchThemed checked={checked} onChange={handleChange} />;
}

function StyleGuide() {
  return (
    <div>
      <Pane>
        <SwitchExample />
      </Pane>
      <Pane>
        <Input />
      </Pane>
      <Pane>
        <ToggleSwitch name="test" options={optionsRule} value="Rule" onChange={noop} />
      </Pane>
      <Pane>
        <Button text="Test Latency" start={<Zap size={16} />} />
        <Button text="Test Latency" start={<Zap size={16} />} isLoading />
        <Button label="Test Latency" />
        <Button label="Button Plain" kind="minimal" />
      </Pane>
      <Pane style={{ paddingLeft: 20 }}>
        <Loading />
      </Pane>
    </div>
  );
}

export default StyleGuide;
