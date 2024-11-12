export const member = () => "I am a exported member of ESM.";
export const defaultMember = () => "I am a default export of ESM.";
export default defaultMember;

const thrower = () => {
  throw new Error("unpleasant wrapped error");
}

export const wrapError = () => {
  thrower();
}
