import fs from 'fs/promises';
import { preferredFolders } from './music-schedule.mjs';

const MUSIC_ROOT = './server/music';
const mp3Filter = (file) => file.match(/\.mp3$/i);

// MP3s in one folder under server/music, as "folder/file.mp3" paths the
// browser requests from /music/. Empty when the folder is missing or has none.
const listFolder = async (folder) => {
	const dir = folder ? `${MUSIC_ROOT}/${folder}` : MUSIC_ROOT;
	try {
		const files = (await fs.readdir(dir)).filter(mp3Filter).sort();
		return files.map((file) => (folder ? `${folder}/${file}` : file));
	} catch {
		return [];
	}
};

let lastChoice;
const announce = (folder, count) => {
	const label = folder || '(root)';
	if (lastChoice === label) return;
	lastChoice = label;
	console.log(`music: website playlist is ${label} (${count} tracks)`);
};

// First folder in the list that holds MP3s, or [] if none do.
const firstWithFiles = async (folders) => {
	if (folders.length === 0) return [];
	const [folder, ...rest] = folders;
	const files = await listFolder(folder);
	if (files.length > 0) {
		announce(folder, files.length);
		return files;
	}
	return firstWithFiles(rest);
};

const reader = async () => {
	// Seasonal folder, then MUSIC_DIR (same precedence as the caster), then the
	// upstream behaviour: loose files in server/music, else server/music/default.
	const files = await firstWithFiles([...preferredFolders(), '', 'default']);
	if (files.length === 0) announce('default', 0);
	return files;
};

export default reader;
