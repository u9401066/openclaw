/**
 * Office document extraction — converts XLSX/XLS/DOCX/PPTX to plain text.
 *
 * Follows the same lazy-loading pattern as pdf-extract.ts to avoid startup cost
 * when Office files are never processed.
 */

let xlsxModulePromise: Promise<typeof import("xlsx")> | null = null;
let mammothModulePromise: Promise<typeof import("mammoth")> | null = null;

async function loadXlsx(): Promise<typeof import("xlsx")> {
  if (!xlsxModulePromise) {
    xlsxModulePromise = import("xlsx").catch((err) => {
      xlsxModulePromise = null;
      throw new Error(`xlsx is required for Excel extraction: ${String(err)}`);
    });
  }
  return xlsxModulePromise;
}

async function loadMammoth(): Promise<typeof import("mammoth")> {
  if (!mammothModulePromise) {
    mammothModulePromise = import("mammoth").catch((err) => {
      mammothModulePromise = null;
      throw new Error(`mammoth is required for DOCX extraction: ${String(err)}`);
    });
  }
  return mammothModulePromise;
}

export const OFFICE_MIME_TYPES = new Set([
  // Excel
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", // .xlsx
  "application/vnd.ms-excel", // .xls
  // Word
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document", // .docx
  // PowerPoint
  "application/vnd.openxmlformats-officedocument.presentationml.presentation", // .pptx
  "application/vnd.ms-powerpoint", // .ppt
]);

/**
 * Extract text content from an Office document buffer.
 * Returns plain text suitable for LLM context injection.
 */
export async function extractOfficeContent(params: {
  buffer: Buffer;
  mimeType: string;
  maxChars?: number;
}): Promise<{ text: string }> {
  const { buffer, mimeType, maxChars = 200_000 } = params;

  let text: string;

  switch (mimeType) {
    case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
    case "application/vnd.ms-excel":
      text = await extractExcel(buffer);
      break;

    case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
      text = await extractDocx(buffer);
      break;

    case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
    case "application/vnd.ms-powerpoint":
      text = await extractPptx(buffer);
      break;

    default:
      text = "";
  }

  if (text.length > maxChars) {
    text = text.slice(0, maxChars);
  }

  return { text };
}

/**
 * Convert Excel workbook to CSV-like text, one sheet at a time.
 */
async function extractExcel(buffer: Buffer): Promise<string> {
  const XLSX = await loadXlsx();
  const workbook = XLSX.read(buffer, { type: "buffer" });
  const parts: string[] = [];

  for (const sheetName of workbook.SheetNames) {
    const sheet = workbook.Sheets[sheetName];
    if (!sheet) {
      continue;
    }
    const csv = XLSX.utils.sheet_to_csv(sheet);
    if (!csv.trim()) {
      continue;
    }
    if (workbook.SheetNames.length > 1) {
      parts.push(`## Sheet: ${sheetName}\n${csv}`);
    } else {
      parts.push(csv);
    }
  }

  return parts.join("\n\n");
}

/**
 * Convert DOCX to plain text via mammoth.
 */
async function extractDocx(buffer: Buffer): Promise<string> {
  const mammoth = await loadMammoth();
  const result = await mammoth.extractRawText({ buffer });
  return result.value;
}

/**
 * Best-effort PPTX text extraction using xlsx's ZIP reader.
 * Extracts text from slide XML nodes.
 */
async function extractPptx(buffer: Buffer): Promise<string> {
  const XLSX = await loadXlsx();
  // PPTX is a ZIP containing XML slides — try to read as workbook for any text
  const workbook = XLSX.read(buffer, { type: "buffer" });
  const parts: string[] = [];
  for (const sheetName of workbook.SheetNames) {
    const sheet = workbook.Sheets[sheetName];
    if (!sheet) {
      continue;
    }
    const text = XLSX.utils.sheet_to_csv(sheet);
    if (text.trim()) {
      parts.push(text);
    }
  }
  if (parts.length > 0) {
    return parts.join("\n\n");
  }
  // If xlsx can't handle it, return empty (PPTX is not well-supported by xlsx)
  return "[PowerPoint content — text extraction limited]";
}
