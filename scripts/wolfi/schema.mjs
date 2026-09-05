#!/usr/bin/env node
// Editor schema shares the reviewed utility catalog with runtime validation/APK selection.
import fs from 'node:fs';
import { UTILITY_CATALOG, PLAYWRIGHT_VERSION } from './config.mjs';
const selector = {type:'string', pattern:'^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$'};
const exactVersion = {type:'string',pattern:'^[0-9]+\\.[0-9]+\\.[0-9]+$'};
const object = (properties, required=[]) => ({type:'object',additionalProperties:false,properties,...(required.length?{required}:{})});
const identity = {type:'integer',minimum:1,maximum:2147483647};
const schema={
  $schema:'http://json-schema.org/draft-07/schema#', title:'Wolfi image profile',
  ...object({
    schemaVersion:{const:2},
    image:object({reference:{type:'string',description:'Single output image with explicit tag.'},platform:{enum:['linux/amd64','linux/arm64']}},['reference','platform']),
    artifacts:object({root:{type:'string',pattern:'^artifacts/[^/]+',description:'Dedicated profile artifact directory; do not overlap profiles.'}},['root']),
    wolfi:object({baseImage:{type:'string'},repositories:object({main:{type:'string',format:'uri'},extra:{type:'string',format:'uri'}},['main','extra'])},['baseImage','repositories']),
    user:object({name:{type:'string',pattern:'^[a-z_][a-z0-9_-]{0,31}$',not:{const:'root'}},uid:identity,gid:identity},['name','uid','gid']),
    devcontainer:{type:'boolean',description:'Editor identity/UID synchronization; requires a named user.'},
    docker:object({cli:selector,buildx:{...selector,description:'Requires docker.cli.'},compose:selector,socket:{type:'boolean',description:'Socket proxy; requires CLI, named user and devcontainer.'}}),
    kaniko:object({version:{...exactVersion,description:'Maintained osscontainertools release. Run kaniko-build in a disposable root job.'}},['version']),
    vscode:object({version:selector,quality:{const:'stable'},extensions:{type:'array',uniqueItems:true,maxItems:256,items:{type:'string',pattern:'^[A-Za-z0-9-]+\\.[A-Za-z0-9._-]+$'}}},['version']),
    build:object({native:object({clang:selector}),python:{type:'array',minItems:1,maxItems:8,uniqueItems:true,items:selector},java:selector,maven:selector,node:selector,npm:selector,rust:object({toolchain:{type:'string',pattern:'^nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}$'},components:{type:'array',uniqueItems:true,items:{enum:['rust-src','rust-analyzer','rustfmt','clippy']}}},['toolchain','components'])}),
    playwright:{description:`Optional matched Chromium + headless shell. true selects ${PLAYWRIGHT_VERSION}; requires build.node/npm. No video.`,oneOf:[{type:'boolean'},object({version:exactVersion},['version'])]},
    utilities:object(Object.fromEntries(Object.entries(UTILITY_CATALOG).map(([key,value])=>[key,{...selector,description:value.description,examples:[value.exampleSelector]}])))
  },['schemaVersion','image','artifacts','wolfi'])
};
const target=new URL('../../config/wolfi.schema.json',import.meta.url);
const text=JSON.stringify(schema,null,2)+'\n';
if(process.argv.includes('--check')) {
 if(fs.readFileSync(target,'utf8')!==text) throw Error('Editor schema is stale; run node scripts/wolfi/schema.mjs');
} else fs.writeFileSync(target,text);
