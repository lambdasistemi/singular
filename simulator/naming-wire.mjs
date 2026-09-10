import {equal} from './core.mjs';
import {decodeAddress, wellFormedFixture} from './naming.mjs';

const bytes = value => ({bytes: [...value]});
const constr = (index, fields) => ({constr: {index, fields}});
const integer = value => ({integer: value});
const list = values => ({list: values});
const byteArray = value => Array.isArray(value) && value.every(byte => Number.isInteger(byte) && byte >= 0 && byte < 256);
const sameKeys = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());

export const encodePaymentDestination = destination => destination === null
  ? constr(0, []) : constr(1, [bytes(destination.bytes)]);

export const encodeRetirementQuorum = quorum => constr(0, [integer(quorum.threshold),
  list(quorum.members.map(bytes))]);

export const encodeNamingDatum = fixture => constr(0, [constr(0, [
  bytes(fixture.controlAddress.bytes),
  encodePaymentDestination(fixture.paymentDestination),
  bytes(fixture.nextControlCommitment.digest),
  encodeRetirementQuorum(fixture.retirementQuorum),
])]);

const decodePaymentDestination = data => {
  if (!sameKeys(data, ['constr']) || !sameKeys(data.constr, ['index', 'fields'])) return undefined;
  const {index, fields} = data.constr;
  if (index === 0 && Array.isArray(fields) && fields.length === 0) return null;
  if (index !== 1 || !Array.isArray(fields) || fields.length !== 1 || !sameKeys(fields[0], ['bytes'])) return undefined;
  return decodeAddress(fields[0].bytes) ?? undefined;
};

const decodeRetirementQuorum = data => {
  if (!sameKeys(data, ['constr']) || data.constr.index !== 0 || !Array.isArray(data.constr.fields)
      || data.constr.fields.length !== 2) return null;
  const [thresholdData, membersData] = data.constr.fields;
  if (!sameKeys(thresholdData, ['integer']) || !Number.isSafeInteger(thresholdData.integer)
      || thresholdData.integer < 0 || !sameKeys(membersData, ['list']) || !Array.isArray(membersData.list)) return null;
  const members = [];
  for (const member of membersData.list) {
    if (!sameKeys(member, ['bytes']) || !byteArray(member.bytes) || member.bytes.length !== 28) return null;
    members.push([...member.bytes]);
  }
  return {members, threshold: thresholdData.integer};
};

export function decodeNamingDatum(data) {
  if (!sameKeys(data, ['constr']) || data.constr.index !== 0 || !Array.isArray(data.constr.fields)
      || data.constr.fields.length !== 1) return null;
  const inner = data.constr.fields[0];
  if (!sameKeys(inner, ['constr']) || inner.constr.index !== 0 || !Array.isArray(inner.constr.fields)
      || inner.constr.fields.length !== 4) return null;
  const [controlData, destinationData, commitmentData, quorumData] = inner.constr.fields;
  if (!sameKeys(controlData, ['bytes']) || !sameKeys(commitmentData, ['bytes'])
      || !byteArray(commitmentData.bytes) || commitmentData.bytes.length !== 32) return null;
  const controlAddress = decodeAddress(controlData.bytes);
  const paymentDestination = decodePaymentDestination(destinationData);
  const retirementQuorum = decodeRetirementQuorum(quorumData);
  if (controlAddress === null || paymentDestination === undefined || retirementQuorum === null) return null;
  const fixture = {controlAddress, paymentDestination,
    nextControlCommitment: {digest: [...commitmentData.bytes]}, retirementQuorum};
  return wellFormedFixture(fixture) ? fixture : null;
}

export const extractNamingDatum = attachment => sameKeys(attachment, ['inline'])
  ? decodeNamingDatum(attachment.inline) : null;

export const namingDatumShape = data => {
  const inner = data?.constr?.fields;
  return data?.constr?.index === 0 && Array.isArray(inner) && inner.length === 1
    && inner[0]?.constr?.index === 0 && Array.isArray(inner[0].constr.fields)
    ? {outerIndex: 0, innerIndex: 0, arity: inner[0].constr.fields.length} : null;
};

export const twoDestinationDatum = fixture => {
  const datum = encodeNamingDatum(fixture);
  datum.constr.fields[0].constr.fields[1] = constr(1,
    [bytes(fixture.paymentDestination.bytes), bytes(fixture.controlAddress.bytes)]);
  return datum;
};

const cborHead = (major, value) => {
  if (!Number.isSafeInteger(value) || value < 0) return null;
  if (value < 24) return [major * 32 + value];
  if (value < 256) return [major * 32 + 24, value];
  if (value < 65536) return [major * 32 + 25, Math.floor(value / 256), value % 256];
  return null;
};

export function serialiseWireData(data) {
  if (sameKeys(data, ['constr']) && sameKeys(data.constr, ['index', 'fields'])) {
    const {index, fields} = data.constr;
    if (!Number.isSafeInteger(index) || index < 0 || index >= 7 || !Array.isArray(fields)) return null;
    const encoded = fields.map(serialiseWireData);
    if (encoded.some(value => value === null)) return null;
    return [216, 121 + index, 159, ...encoded.flat(), 255];
  }
  if (sameKeys(data, ['bytes'])) {
    if (!byteArray(data.bytes) || data.bytes.length > 64) return null;
    const head = cborHead(2, data.bytes.length);
    return head === null ? null : [...head, ...data.bytes];
  }
  if (sameKeys(data, ['integer'])) return cborHead(0, data.integer);
  if (sameKeys(data, ['list']) && Array.isArray(data.list)) {
    const encoded = data.list.map(serialiseWireData);
    if (encoded.some(value => value === null)) return null;
    return [159, ...encoded.flat(), 255];
  }
  return null;
}

function parseWireData(input, cursor) {
  const header = input[cursor];
  if (header === 216 && input[cursor + 1] >= 121 && input[cursor + 1] < 128
      && input[cursor + 2] === 159) {
    const parsed = parseWireItems(input, cursor + 3);
    return parsed === null ? null : [constr(input[cursor + 1] - 121, parsed[0]), parsed[1]];
  }
  if (header === 159) {
    const parsed = parseWireItems(input, cursor + 1);
    return parsed === null ? null : [list(parsed[0]), parsed[1]];
  }
  if (header >= 64 && header < 88) {
    const length = header - 64;
    return cursor + 1 + length <= input.length
      ? [bytes(input.slice(cursor + 1, cursor + 1 + length)), cursor + 1 + length] : null;
  }
  if (header === 88) {
    const length = input[cursor + 1];
    return length >= 24 && length <= 64 && cursor + 2 + length <= input.length
      ? [bytes(input.slice(cursor + 2, cursor + 2 + length)), cursor + 2 + length] : null;
  }
  if (header < 24) return [integer(header), cursor + 1];
  if (header === 24) {
    const value = input[cursor + 1];
    return value >= 24 ? [integer(value), cursor + 2] : null;
  }
  if (header === 25) {
    const high = input[cursor + 1], low = input[cursor + 2];
    if (high === undefined || low === undefined) return null;
    const value = high * 256 + low;
    return value >= 256 ? [integer(value), cursor + 3] : null;
  }
  return null;
}

function parseWireItems(input, cursor) {
  const values = [];
  while (cursor < input.length && input[cursor] !== 255) {
    const parsed = parseWireData(input, cursor);
    if (parsed === null || parsed[1] <= cursor) return null;
    values.push(parsed[0]);
    cursor = parsed[1];
  }
  return input[cursor] === 255 ? [values, cursor + 1] : null;
}

export function deserialiseWireData(input) {
  if (!byteArray(input)) return null;
  const parsed = parseWireData(input, 0);
  return parsed !== null && parsed[1] === input.length ? parsed[0] : null;
}

export const serialiseNamingDatum = fixture => serialiseWireData(encodeNamingDatum(fixture));

export const deserialiseNamingDatum = input => {
  const data = deserialiseWireData(input);
  return data === null ? null : decodeNamingDatum(data);
};

const natData = value => Number.isSafeInteger(value) && value >= 0 ? integer(value) : null;
const decodeNat = data => sameKeys(data, ['integer']) && Number.isSafeInteger(data.integer)
  && data.integer >= 0 ? data.integer : null;
const encodeRepresentative = value => constr(0, [integer(value.registry), integer(value.key),
  integer(value.policy), integer(value.assetScope)]);
const decodeRepresentative = data => {
  if (!sameKeys(data, ['constr']) || data.constr.index !== 0 || !Array.isArray(data.constr.fields)
      || data.constr.fields.length !== 4) return null;
  const values = data.constr.fields.map(decodeNat);
  return values.some(value => value === null) ? null
    : {registry: values[0], key: values[1], policy: values[2], assetScope: values[3]};
};
const encodeOutput = value => constr(0, [encodeRepresentative(value.representative),
  integer(value.quantity), integer(value.destination), integer(value.datum), integer(value.value)]);
const decodeOutput = data => {
  if (!sameKeys(data, ['constr']) || data.constr.index !== 0 || !Array.isArray(data.constr.fields)
      || data.constr.fields.length !== 5) return null;
  const [representativeData, ...numberData] = data.constr.fields;
  const representative = decodeRepresentative(representativeData);
  const values = numberData.map(decodeNat);
  return representative === null || values.some(value => value === null) ? null
    : {representative, quantity: values[0], destination: values[1], datum: values[2], value: values[3]};
};
const encodeProposal = proposal => constr(0, [integer(proposal.registry), integer(proposal.key),
  integer(proposal.applicationPolicy), integer(proposal.refundAddress), encodeOutput(proposal.initial),
  list(proposal.scope.map(integer))]);
const decodeProposal = data => {
  if (!sameKeys(data, ['constr']) || data.constr.index !== 0 || !Array.isArray(data.constr.fields)
      || data.constr.fields.length !== 6) return null;
  const [registryData, keyData, policyData, refundData, outputData, scopeData] = data.constr.fields;
  const numbers = [registryData, keyData, policyData, refundData].map(decodeNat);
  const initial = decodeOutput(outputData);
  if (numbers.some(value => value === null) || initial === null || !sameKeys(scopeData, ['list'])
      || !Array.isArray(scopeData.list)) return null;
  const scope = scopeData.list.map(decodeNat);
  return scope.some(value => value === null) ? null : {registry: numbers[0], key: numbers[1],
    applicationPolicy: numbers[2], refundAddress: numbers[3], initial, scope};
};
const insertAsset = proposal => ({policy: proposal.applicationPolicy, name: {insert: {proposal}}});
export const encodeInsertRequest = request => request?.operation === 'insert'
  && request.proposal && equal(request.token, insertAsset(request.proposal))
  ? constr(0, [encodeProposal(request.proposal)]) : null;
export const decodeInsertCommitment = data => sameKeys(data, ['constr']) && data.constr.index === 0
  && Array.isArray(data.constr.fields) && data.constr.fields.length === 1
  ? decodeProposal(data.constr.fields[0]) : null;
export const decodeInsertRequestCommitment = (request, data) => {
  const expected = decodeInsertCommitment(encodeInsertRequest(request));
  const proposal = decodeInsertCommitment(data);
  return expected !== null && proposal !== null && equal(proposal, expected) ? proposal : null;
};
export const insertRequestShape = data => {
  const proposal = data?.constr?.fields;
  return Number.isSafeInteger(data?.constr?.index) && Array.isArray(proposal) && proposal.length === 1
    && Number.isSafeInteger(proposal[0]?.constr?.index) && Array.isArray(proposal[0]?.constr?.fields)
    ? {commitmentIndex: data.constr.index, commitmentArity: 1,
      proposalIndex: proposal[0].constr.index, proposalArity: proposal[0].constr.fields.length}
    : null;
};
export const serialiseInsertRequest = request => {
  const data = encodeInsertRequest(request);
  return data === null ? null : serialiseWireData(data);
};
export const deserialiseInsertCommitment = input => {
  const data = deserialiseWireData(input);
  return data === null ? null : decodeInsertCommitment(data);
};
export const deserialiseInsertRequest = (request, input) => {
  const data = deserialiseWireData(input);
  return data === null ? null : decodeInsertRequestCommitment(request, data);
};
