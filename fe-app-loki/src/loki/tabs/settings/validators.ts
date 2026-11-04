import { validateSingBoxFilePath } from '../../../validators/validateSingBoxFilePath';

export function validateSingBoxPath(value: string, fileName: string) {
  return validateSingBoxFilePath(`${value || ''}`, fileName);
}
