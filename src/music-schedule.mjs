// Picks which folder under server/music the site's player should use today.
// Mirrors the caster's logic in caster/entrypoint.sh (active_music_dir) so the
// website and the IPTV stream play from the same folder:
//
//   MUSIC_SCHEDULE  folder=MM-DD:MM-DD[,folder=MM-DD:MM-DD...]
//                   start day included, end day excluded, ranges may wrap the
//                   year end, first match wins
//   MUSIC_DIR       year-round folder when no schedule entry matches
//   MUSIC_TODAY     MMDD override for testing
//
// Folder values are names relative to server/music. The caster writes them as
// container paths (/music/christmas); a leading /music/ is stripped so the one
// .env serves both services.

const CASTER_ROOT = '/music';

// "/music/christmas" -> "christmas", "christmas" -> "christmas", "/music" -> ""
export const folderName = (value) => {
	if (!value) return '';
	let name = value.trim();
	if (name === CASTER_ROOT) return '';
	if (name.startsWith(`${CASTER_ROOT}/`)) name = name.slice(CASTER_ROOT.length + 1);
	return name.replace(/^\/+|\/+$/g, '');
};

// MMDD for today in the server's TZ (TZ env, as the caster uses).
export const todayMMDD = (now = new Date()) => {
	if (process.env.MUSIC_TODAY) return process.env.MUSIC_TODAY.replace('-', '');
	const parts = new Intl.DateTimeFormat('en-US', {
		timeZone: process.env.TZ || undefined,
		month: '2-digit',
		day: '2-digit',
	}).formatToParts(now);
	const get = (type) => parts.find((p) => p.type === type).value;
	return `${get('month')}${get('day')}`;
};

const mmdd = (s) => {
	const m = s.trim().match(/^(\d{2})-?(\d{2})$/);
	return m ? Number(`${m[1]}${m[2]}`) : NaN;
};

const parseEntry = (entry) => {
	const [folder, range] = entry.split('=');
	const [startRaw, endRaw] = (range || '').split(':');
	const start = mmdd(startRaw || '');
	const end = mmdd(endRaw || '');
	if (!folder || Number.isNaN(start) || Number.isNaN(end)) {
		console.warn(`music schedule: ignoring malformed entry "${entry}"`);
		return null;
	}
	return { folder: folderName(folder), start, end };
};

// Returns the folder name scheduled for `today`, or '' when none matches.
export const scheduledFolder = (schedule, today = todayMMDD()) => {
	if (!schedule) return '';
	const t = Number(today);
	const match = schedule.split(',')
		.map((e) => e.trim())
		.filter(Boolean)
		.map(parseEntry)
		.filter(Boolean)
		.find(({ start, end }) => (start <= end
			? (t >= start && t < end)
			: (t >= start || t < end)));
	return match ? match.folder : '';
};

// Candidate folders in order of preference: today's season, then MUSIC_DIR.
// Each may be '' (meaning the music root) or missing; the caller checks what
// actually exists and holds MP3s.
export const preferredFolders = (env = process.env) => {
	const out = [];
	const season = scheduledFolder(env.MUSIC_SCHEDULE);
	if (season) out.push(season);
	if (env.MUSIC_DIR !== undefined) out.push(folderName(env.MUSIC_DIR));
	return out;
};
