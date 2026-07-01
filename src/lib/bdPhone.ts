export const BD_MOBILE_PHONE_REGEX = /^(01[3-9][0-9]{8}|\+8801[3-9][0-9]{8})$/;

export const BD_MOBILE_PHONE_ERROR =
  'Enter a valid Bangladesh mobile number, e.g. 01712345678 or +8801712345678.';

export const normalizePhoneInput = (value: string) =>
  value.replace(/[^\d+]/g, '').replace(/(?!^)\+/g, '');

export const validateBDMobilePhone = (value: string) =>
  BD_MOBILE_PHONE_REGEX.test(value.trim());

export const assertBDMobilePhone = (value: string) => {
  const phone = value.trim();
  if (!phone) {
    throw new Error('Phone number is required.');
  }
  if (!validateBDMobilePhone(phone)) {
    throw new Error(BD_MOBILE_PHONE_ERROR);
  }
  return phone;
};

export const getPhoneSearchTerms = (value: string) => {
  const phone = normalizePhoneInput(value.trim());
  if (phone.startsWith('+8801') && phone.length > 4) {
    return [phone, `0${phone.slice(4)}`];
  }
  if (phone.startsWith('01') && phone.length > 1) {
    return [phone, `+88${phone}`];
  }
  return phone ? [phone] : [];
};
