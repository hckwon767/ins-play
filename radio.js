/* radio.js — get_radio.sh 로직을 JavaScript로 포팅
 * inlive.co.kr에서 라이브 채널 목록을 가져와 PLS를 파싱한다.
 *
 * CORS 우회: GitHub Pages는 순수 클라이언트이므로
 * allorigins.win 프록시를 통해 inlive.co.kr에 접근한다.
 *
 * 사용법:
 *   import { fetchChannels, HASHTAGS } from './radio.js';
 *   const channels = await fetchChannels(['%F0%9F%8E%B6%20%EA%B0%80%EC%9A%94'], onProgress);
 */

// ── 설정 ────────────────────────────────────────────────────────
const INLIVE_BASE   = 'https://www.inlive.co.kr';
const PROXY_RAW     = 'https://api.allorigins.win/raw?url=';
const PROXY_GET     = 'https://api.allorigins.win/get?url=';   // JSON 래퍼 (fallback)

export const HASHTAGS = [
  { label: '🎵 가요',  value: '%F0%9F%8E%B6%20%EA%B0%80%EC%9A%94' },
  { label: '종합',     value: '%EC%A2%85%ED%95%A9' },
  { label: '뉴스',     value: '%EB%89%B4%EC%8A%A4' },
  { label: '팝',       value: '%ED%8C%9D' },
  { label: '재즈',     value: '%EC%9E%AC%EC%A6%88' },
  { label: '트로트',   value: '%ED%8A%B8%EB%A1%9C%ED%8A%B8' },
  { label: '클래식',   value: '%ED%81%B4%EB%9E%98%EC%8B%9D' },
  { label: 'OST',      value: 'OST' },
];

// ── 내부 헬퍼 ────────────────────────────────────────────────────

/** 프록시를 통해 GET 요청 → 문자열 반환 */
async function proxyGet(url) {
  const res = await fetch(PROXY_RAW + encodeURIComponent(url));
  if (!res.ok) throw new Error(`proxyGet ${res.status}: ${url}`);
  return res.text();
}

/** 프록시를 통해 POST 요청 → 문자열 반환
 *  allorigins /raw는 POST를 지원하므로 그대로 전달한다. */
async function proxyPost(url, body, csrfToken) {
  const res = await fetch(PROXY_RAW + encodeURIComponent(url), {
    method: 'POST',
    headers: {
      'Content-Type':    'application/x-www-form-urlencoded; charset=UTF-8',
      'X-Requested-With':'XMLHttpRequest',
      'X-CSRF-TOKEN':    csrfToken,
      'Origin':          INLIVE_BASE,
      'Referer':         `${INLIVE_BASE}/toplive`,
      'User-Agent':      'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
    },
    body,
  });
  if (!res.ok) throw new Error(`proxyPost ${res.status}`);
  return res.text();
}

/** EUC-KR로 인코딩된 PLS를 디코딩 (브라우저는 UTF-8 fetch 기본값이므로
 *  프록시가 이미 UTF-8로 변환해 주는 경우가 많다. 아닐 경우 대비). */
function decodePls(raw) {
  // 깨진 문자가 없으면 그대로 반환
  if (!/[^\x00-\x7F]/.test(raw) || raw.includes('File1=')) return raw;
  try {
    const bytes = Uint8Array.from(raw.split('').map(c => c.charCodeAt(0)));
    return new TextDecoder('euc-kr').decode(bytes);
  } catch {
    return raw;
  }
}

/** PLS 텍스트 → { streamUrl, title } */
function parsePls(raw) {
  const text = decodePls(raw);
  const fileMatch  = text.match(/File1=(.+)/);
  const titleMatch = text.match(/Title1=(.+)/);
  if (!fileMatch) return null;
  return {
    streamUrl: fileMatch[1].trim(),
    title:     titleMatch ? titleMatch[1].trim() : '',
  };
}

// ── 공개 API ─────────────────────────────────────────────────────

/**
 * get_radio.sh의 핵심 로직을 수행한다.
 *
 * @param {string[]} hashtags   - HASHTAGS[].value 배열
 * @param {Function} [onProgress] - ({ step, done, total }) 콜백
 * @returns {Promise<Channel[]>}
 *
 * Channel = { bsid, name, streamUrl, thumbUrl }
 */
export async function fetchChannels(hashtags = [], onProgress = () => {}) {

  // ── Step 1: CSRF 토큰 획득 ──────────────────────────────────
  onProgress({ step: 'csrf', done: 0, total: 0 });
  const mainHtml = await proxyGet(`${INLIVE_BASE}/toplive`);
  const csrfMatch = mainHtml.match(/meta[^>]+name="csrf-token"[^>]+content="([^"]+)"/);
  if (!csrfMatch) throw new Error('CSRF 토큰을 찾을 수 없습니다');
  const csrfToken = csrfMatch[1];

  // ── Step 2: 해시태그별 방송 ID 수집 ────────────────────────
  onProgress({ step: 'ids', done: 0, total: hashtags.length });
  const allIds = new Set();

  for (let i = 0; i < hashtags.length; i++) {
    try {
      const body = `page_no=1&hashtag=${hashtags[i]}&searchval=`;
      const raw  = await proxyPost(`${INLIVE_BASE}/ajaxGetTopLiveList`, body, csrfToken);
      const json = JSON.parse(raw);
      (json.result || []).forEach(item => item.f_bsid && allIds.add(item.f_bsid));
    } catch (e) {
      console.warn('[radio.js] hashtag fetch failed:', hashtags[i], e);
    }
    onProgress({ step: 'ids', done: i + 1, total: hashtags.length });
  }

  if (allIds.size === 0) throw new Error('방송 중인 채널이 없습니다');

  // ── Step 3: 각 방송국 PLS 파싱 ─────────────────────────────
  const ids = [...allIds];
  onProgress({ step: 'pls', done: 0, total: ids.length });

  let done = 0;
  const channels = (
    await Promise.all(
      ids.map(async bsid => {
        try {
          const plsUrl = `http://${bsid}.inlive.co.kr/live/listen.pls`;
          const raw    = await proxyGet(plsUrl);
          const parsed = parsePls(raw);
          if (!parsed) return null;

          const name = parsed.title || bsid;
          return {
            bsid,
            name,
            streamUrl: parsed.streamUrl,
            thumbUrl:  `https://cdn.inlive.co.kr/profile/${bsid}.jpg`,
          };
        } catch {
          return null;
        } finally {
          onProgress({ step: 'pls', done: ++done, total: ids.length });
        }
      })
    )
  ).filter(Boolean);

  return channels;
}

/**
 * PLS 형식 문자열 생성 (get_radio.sh 출력과 동일한 포맷)
 * 파일 다운로드나 외부 플레이어 연동 시 사용
 */
export function toPls(channels) {
  const now = new Date().toLocaleString('ko-KR', {
    timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit',
    day: '2-digit', hour: '2-digit', minute: '2-digit',
  });
  const lines = [
    '#',
    `# LastUpdate: ${now}`,
    '[playlist]',
  ];
  channels.forEach((ch, i) => {
    lines.push(`File${i + 1}=${ch.streamUrl}`);
    lines.push(`Title${i + 1}=${ch.name.replace(/ /g, '_')}`);
  });
  lines.push(`NumberOfEntries=${channels.length}`);
  lines.push('Version=2');
  return lines.join('\n');
}
