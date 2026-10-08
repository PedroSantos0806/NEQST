/**
 * Leitura do QR Code e da tag NFC no navegador.
 *
 * O app nativo usa expo-camera; na web não existe equivalente único:
 *   - Chrome/Android: BarcodeDetector, nativo e rápido
 *   - Safari/Firefox: jsQR sobre um <canvas>
 *
 * Na prática, a maioria dos acessos vem de quem já escaneou com a
 * câmera do sistema e caiu na rota /q/:courtId — nesse caminho não há
 * scanner nenhum, só a URL. O scanner aqui é para quem abre o app
 * primeiro.
 */
import jsQR from "jsqr";

type BarcodeDetectorLike = {
  detect(source: CanvasImageSource): Promise<Array<{ rawValue: string }>>;
};

declare global {
  interface Window {
    BarcodeDetector?: new (options?: { formats: string[] }) => BarcodeDetectorLike;
  }
  interface NDEFReadingEventLike extends Event {
    message: { records: Array<{ recordType: string; data?: DataView }> };
  }
  interface Window {
    NDEFReader?: new () => {
      scan(options?: { signal?: AbortSignal }): Promise<void>;
      addEventListener(type: "reading", listener: (event: NDEFReadingEventLike) => void): void;
      addEventListener(type: "readingerror", listener: () => void): void;
    };
  }
}

export const qrSupported = () => Boolean(navigator.mediaDevices?.getUserMedia);
export const nfcSupported = () => typeof window !== "undefined" && "NDEFReader" in window;

export class ScanError extends Error {
  constructor(message: string, readonly kind: "denied" | "unsupported" | "failed") {
    super(message);
    this.name = "ScanError";
  }
}

export interface QrScanner {
  stop(): void;
}

/**
 * Liga a câmera e chama `onRead` no primeiro código lido.
 * Devolve um handle para desligar — esquecer disso deixa a luz da
 * câmera acesa, que assusta o usuário.
 */
export async function startQrScanner(
  video: HTMLVideoElement,
  onRead: (value: string) => void,
): Promise<QrScanner> {
  if (!qrSupported()) {
    throw new ScanError("Este navegador não dá acesso à câmera.", "unsupported");
  }

  let stream: MediaStream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: { ideal: "environment" } },
      audio: false,
    });
  } catch {
    throw new ScanError("Permita o acesso à câmera para escanear o QR Code.", "denied");
  }

  video.srcObject = stream;
  video.setAttribute("playsinline", "true");
  await video.play().catch(() => undefined);

  const detector = window.BarcodeDetector
    ? new window.BarcodeDetector({ formats: ["qr_code"] })
    : null;

  const canvas = document.createElement("canvas");
  const context = canvas.getContext("2d", { willReadFrequently: true });

  let active = true;
  let frame = 0;

  const stop = () => {
    active = false;
    cancelAnimationFrame(frame);
    stream.getTracks().forEach((track) => track.stop());
    video.srcObject = null;
  };

  const tick = async () => {
    if (!active) return;

    if (video.readyState === video.HAVE_ENOUGH_DATA) {
      try {
        if (detector) {
          const [found] = await detector.detect(video);
          if (found?.rawValue) {
            stop();
            onRead(found.rawValue);
            return;
          }
        } else if (context) {
          canvas.width = video.videoWidth;
          canvas.height = video.videoHeight;
          context.drawImage(video, 0, 0, canvas.width, canvas.height);
          const image = context.getImageData(0, 0, canvas.width, canvas.height);
          const found = jsQR(image.data, image.width, image.height, {
            inversionAttempts: "dontInvert",
          });
          if (found?.data) {
            stop();
            onRead(found.data);
            return;
          }
        }
      } catch {
        // Quadro ruim acontece; o próximo resolve.
      }
    }

    frame = requestAnimationFrame(() => void tick());
  };

  void tick();
  return { stop };
}

/** Web NFC: só Chrome no Android, e só em HTTPS. */
export async function readNfcTag(signal: AbortSignal): Promise<string> {
  if (!window.NDEFReader) {
    throw new ScanError("Este navegador não lê tags NFC. Use o QR Code.", "unsupported");
  }

  const reader = new window.NDEFReader();

  return await new Promise<string>((resolve, reject) => {
    reader.addEventListener("reading", (event) => {
      const record = event.message.records.find(
        (r) => r.recordType === "url" || r.recordType === "text",
      );
      if (!record?.data) {
        reject(new ScanError("A tag não trouxe um endereço válido.", "failed"));
        return;
      }
      resolve(new TextDecoder().decode(record.data));
    });

    reader.addEventListener("readingerror", () => {
      reject(new ScanError("Não conseguimos ler a tag. Tente de novo.", "failed"));
    });

    reader.scan({ signal }).catch(() => {
      reject(new ScanError("Permita o acesso ao NFC para fazer o check-in.", "denied"));
    });
  });
}
