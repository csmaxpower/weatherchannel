// M3U playlist for IPTV apps, describing the 24/7 channel the caster publishes.
//
// The endpoints mirror the caster's environment (see deploy/docker-compose.yml)
// so the playlist cannot drift from what is actually on the wire. Apps differ
// in which URL schemes they accept, so the same feed is listed several ways:
// raw multicast, MediaMTX HLS and MediaMTX RTSP. Most players show these as
// separate channels; pick whichever one plays.
//
// `?only=` narrows it to a single entry (multicast | hls | rtsp) for apps that
// cannot cope with alternatives.

const MULTICAST_ADDR = process.env.MULTICAST_ADDR ?? '';
const MULTICAST_PORT = process.env.MULTICAST_PORT ?? '5004';
const MEDIAMTX_HOST = process.env.MEDIAMTX_HOST ?? '';
const MEDIAMTX_PATH = process.env.MEDIAMTX_PATH ?? 'weather';
const CHANNEL_NAME = process.env.CHANNEL_NAME ?? 'WeatherStar 4000+';

const buildEntries = () => {
	const entries = [];
	if (MULTICAST_ADDR) {
		// udp://@ is the conventional multicast form and the one most IPTV apps
		// and VLC expect; a bare udp:// is rejected or treated as unicast by some.
		entries.push({
			key: 'multicast',
			name: `${CHANNEL_NAME} (Multicast)`,
			url: `udp://@${MULTICAST_ADDR}:${MULTICAST_PORT}`,
		});
	}
	if (MEDIAMTX_HOST) {
		entries.push({
			key: 'hls',
			name: `${CHANNEL_NAME} (HLS)`,
			url: `http://${MEDIAMTX_HOST}:8888/${MEDIAMTX_PATH}/index.m3u8`,
		});
		entries.push({
			key: 'rtsp',
			name: `${CHANNEL_NAME} (RTSP)`,
			url: `rtsp://${MEDIAMTX_HOST}:8554/${MEDIAMTX_PATH}`,
		});
	}
	return entries;
};

const iptvPlaylist = (req, res) => {
	const all = buildEntries();
	if (all.length === 0) {
		res.status(404).type('text/plain').send('No stream endpoints configured (set MULTICAST_ADDR and/or MEDIAMTX_HOST)\n');
		return;
	}

	const only = typeof req.query.only === 'string' ? req.query.only.toLowerCase() : null;
	const entries = all.filter((e) => !only || e.key === only);
	if (entries.length === 0) {
		res.status(400).type('text/plain').send('only= must be multicast, hls or rtsp\n');
		return;
	}

	const lines = ['#EXTM3U'];
	entries.forEach((e) => {
		lines.push(`#EXTINF:-1 tvg-id="${e.key}" group-title="${CHANNEL_NAME}",${e.name}`);
		lines.push(e.url);
	});

	// Never cache: the endpoints change with a redeploy and a stale playlist
	// points a player at nothing.
	res.set('Cache-Control', 'no-store');
	res.type('audio/x-mpegurl');
	res.send(`${lines.join('\n')}\n`);
};

export default iptvPlaylist;
