import { FAKEIP_CHECK_DOMAIN } from '../../../constants';
import { createBaseApiRequest, IBaseApiResponse } from '../../api';

interface IGetFakeIpCheckResponse {
  fakeip: boolean;
  IP: string;
}

export async function getFakeIpCheck(): Promise<
  IBaseApiResponse<IGetFakeIpCheckResponse>
> {
  return createBaseApiRequest<IGetFakeIpCheckResponse>(
    () =>
      fetch(`https://${FAKEIP_CHECK_DOMAIN}/check`, {
        method: 'GET',
      }),
    {
      operationName: 'getFakeIpCheck',
      timeoutMs: 5000,
    },
  );
}
