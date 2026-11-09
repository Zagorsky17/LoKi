import { downloadFile } from './downloadFile';

export function downloadAsTxt(text: string, filename: string) {
  downloadFile(text, filename.endsWith('.txt') ? filename : `${filename}.txt`);
}
