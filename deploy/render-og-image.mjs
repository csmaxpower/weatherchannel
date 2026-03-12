/**
 * Renders the OpenGraph preview image using satori (HTML-to-SVG) + resvg (SVG-to-PNG).
 * No browser or system dependencies required.
 *
 * Usage:
 *   node deploy/render-og-image.mjs
 *
 * Output: deploy/og-image.png
 */

import satori from 'satori';
import { Resvg } from '@resvg/resvg-js';
import { readFileSync, writeFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const fontsDir = resolve(__dirname, '..', 'server', 'fonts');
const bgPath = resolve(__dirname, '..', 'server', 'images', 'backgrounds', '1.png');

// Load fonts
const star4000 = readFileSync(resolve(fontsDir, 'Star4000.woff'));
const star4000Small = readFileSync(resolve(fontsDir, 'Star4000 Small.woff'));
const star4000Large = readFileSync(resolve(fontsDir, 'Star4000 Large.woff'));

// Load background image as base64 data URI
const bgData = readFileSync(bgPath);
const bgDataUri = `data:image/png;base64,${bgData.toString('base64')}`;

// Text shadow style (matching ws4kp _utils.scss mixin)
const textShadow = '3px 3px 0 black, -1.5px -1.5px 0 black, 0 -1.5px 0 black, 1.5px -1.5px 0 black, 1.5px 0 0 black, 1.5px 1.5px 0 black, 0 1.5px 0 black, -1.5px 1.5px 0 black, -1.5px 0 0 black';
const textShadowHeavy = '4px 4px 0 black, -2px -2px 0 black, 0 -2px 0 black, 2px -2px 0 black, 2px 0 0 black, 2px 2px 0 black, 0 2px 0 black, -2px 2px 0 black, -2px 0 0 black';

const WIDTH = 1200;
const HEIGHT = 630;

const markup = {
	type: 'div',
	props: {
		style: {
			width: `${WIDTH}px`,
			height: `${HEIGHT}px`,
			display: 'flex',
			flexDirection: 'column',
			backgroundImage: `url(${bgDataUri})`,
			backgroundSize: 'cover',
			backgroundPosition: 'center',
			position: 'relative',
		},
		children: [
			// Main content area
			{
				type: 'div',
				props: {
					style: {
						display: 'flex',
						flexDirection: 'column',
						padding: '90px 100px 0 135px',
						flex: 1,
					},
					children: [
						// Title
						{
							type: 'div',
							props: {
								style: {
									fontFamily: 'Star4000 Large',
									fontSize: '52px',
									color: '#FFFF00',
									textTransform: 'uppercase',
									textShadow: textShadowHeavy,
									lineHeight: 1.3,
									marginLeft: '-25px',
								},
								children: 'RandHarris.Org - Weather',
							},
						},
						// Separator
						{
							type: 'div',
							props: {
								style: {
									width: '100%',
									height: '2px',
									background: 'rgba(255, 255, 255, 0.3)',
									marginTop: '18px',
									marginBottom: '18px',
								},
							},
						},
						// Description lines
						{
							type: 'div',
							props: {
								style: {
									fontFamily: 'Star4000',
									fontSize: '34px',
									color: 'white',
									textTransform: 'uppercase',
									textShadow,
									lineHeight: 1.5,
									display: 'flex',
									flexDirection: 'column',
								},
								children: [
									{ type: 'span', props: { children: 'Live weather forecasts, radar,' } },
									{ type: 'span', props: { children: 'hourly conditions & more.' } },
									{ type: 'span', props: { children: 'Powered by the National' } },
									{ type: 'span', props: { children: 'Weather Service.' } },
								],
							},
						},
					],
				},
			},
			// Footer bar
			{
				type: 'div',
				props: {
					style: {
						display: 'flex',
						justifyContent: 'space-between',
						alignItems: 'center',
						padding: '0 135px 0 135px',
						height: '70px',
					},
					children: [
						{
							type: 'div',
							props: {
								style: {
									fontFamily: 'Star4000 Small',
									fontSize: '28px',
									color: 'white',
									textShadow,
								},
								children: 'https://randharris.org/weather',
							},
						},
						{
							type: 'div',
							props: {
								style: {
									fontFamily: 'Star4000 Small',
									fontSize: '24px',
									color: '#FFFF00',
									textShadow,
								},
								children: 'WeatherStar 4000+',
							},
						},
					],
				},
			},
		],
	},
};

const svg = await satori(markup, {
	width: WIDTH,
	height: HEIGHT,
	fonts: [
		{ name: 'Star4000', data: star4000, weight: 400, style: 'normal' },
		{ name: 'Star4000 Small', data: star4000Small, weight: 400, style: 'normal' },
		{ name: 'Star4000 Large', data: star4000Large, weight: 400, style: 'normal' },
	],
});

const resvg = new Resvg(svg, {
	fitTo: { mode: 'width', value: WIDTH * 2 },
});
const png = resvg.render().asPng();

const outputPath = resolve(__dirname, 'og-image.png');
writeFileSync(outputPath, png);
console.log(`OpenGraph image saved to ${outputPath} (${(png.length / 1024).toFixed(0)} KB)`);
