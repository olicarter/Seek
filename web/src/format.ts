/** 245 → "4:05". */
export function duration(seconds?: number): string {
  if (seconds === undefined || !isFinite(seconds)) return "";
  const s = Math.round(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/** 1_500_000 bytes a second → "1.4 MB/s". */
export function speed(bytesPerSecond: number): string {
  if (bytesPerSecond <= 0) return "";
  const mb = bytesPerSecond / 1_048_576;
  return mb >= 1 ? `${mb.toFixed(1)} MB/s` : `${Math.round(bytesPerSecond / 1024)} KB/s`;
}
