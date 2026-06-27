SET session_replication_role = replica;

--
-- PostgreSQL database dump
--

-- \restrict 9ZdedA8I2YzbqYA77YBU9xaM1kWsw6gIOZHmT9G5uNfIiQtLVRvVLPsS3vRaRpf

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: audit_log_entries; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."audit_log_entries" ("instance_id", "id", "payload", "created_at", "ip_address") FROM stdin;
\.


--
-- Data for Name: custom_oauth_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."custom_oauth_providers" ("id", "provider_type", "identifier", "name", "client_id", "client_secret", "acceptable_client_ids", "scopes", "pkce_enabled", "attribute_mapping", "authorization_params", "enabled", "email_optional", "issuer", "discovery_url", "skip_nonce_check", "cached_discovery", "discovery_cached_at", "authorization_url", "token_url", "userinfo_url", "jwks_uri", "created_at", "updated_at") FROM stdin;
\.


--
-- Data for Name: flow_state; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."flow_state" ("id", "user_id", "auth_code", "code_challenge_method", "code_challenge", "provider_type", "provider_access_token", "provider_refresh_token", "created_at", "updated_at", "authentication_method", "auth_code_issued_at", "invite_token", "referrer", "oauth_client_state_id", "linking_target_id", "email_optional") FROM stdin;
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."users" ("instance_id", "id", "aud", "role", "email", "encrypted_password", "email_confirmed_at", "invited_at", "confirmation_token", "confirmation_sent_at", "recovery_token", "recovery_sent_at", "email_change_token_new", "email_change", "email_change_sent_at", "last_sign_in_at", "raw_app_meta_data", "raw_user_meta_data", "is_super_admin", "created_at", "updated_at", "phone", "phone_confirmed_at", "phone_change", "phone_change_token", "phone_change_sent_at", "email_change_token_current", "email_change_confirm_status", "banned_until", "reauthentication_token", "reauthentication_sent_at", "is_sso_user", "deleted_at", "is_anonymous") FROM stdin;
00000000-0000-0000-0000-000000000000	6d459eb2-989d-43ee-9f1d-8f283a9faa94	authenticated	authenticated	siamsifat244@gmail.com	$2a$10$eDCJW9avpRD8h4mf6yjGiunbcjqKs27cQAuAINIMYmoIBahN/OoC.	2026-06-08 12:21:20.406906+00	\N		2026-06-08 12:13:12.2656+00		\N			\N	2026-06-12 22:35:36.272447+00	{"provider": "email", "providers": ["email"]}	{"sub": "6d459eb2-989d-43ee-9f1d-8f283a9faa94", "email": "siamsifat244@gmail.com", "full_name": "sifat", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "email_verified": true, "phone_verified": false}	\N	2026-06-08 12:13:12.213129+00	2026-06-12 22:35:36.304568+00	\N	\N			\N		0	\N		\N	f	\N	f
\.


--
-- Data for Name: identities; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."identities" ("provider_id", "user_id", "identity_data", "provider", "last_sign_in_at", "created_at", "updated_at", "id") FROM stdin;
6d459eb2-989d-43ee-9f1d-8f283a9faa94	6d459eb2-989d-43ee-9f1d-8f283a9faa94	{"sub": "6d459eb2-989d-43ee-9f1d-8f283a9faa94", "email": "siamsifat244@gmail.com", "full_name": "sifat", "email_verified": false, "phone_verified": false}	email	2026-06-08 12:13:12.255003+00	2026-06-08 12:13:12.255053+00	2026-06-08 12:13:12.255053+00	f81739d6-1843-4a34-8a39-322eb952e518
\.


--
-- Data for Name: instances; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."instances" ("id", "uuid", "raw_base_config", "created_at", "updated_at") FROM stdin;
\.


--
-- Data for Name: oauth_clients; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."oauth_clients" ("id", "client_secret_hash", "registration_type", "redirect_uris", "grant_types", "client_name", "client_uri", "logo_uri", "created_at", "updated_at", "deleted_at", "client_type", "token_endpoint_auth_method") FROM stdin;
\.


--
-- Data for Name: sessions; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."sessions" ("id", "user_id", "created_at", "updated_at", "factor_id", "aal", "not_after", "refreshed_at", "user_agent", "ip", "tag", "oauth_client_id", "refresh_token_hmac_key", "refresh_token_counter", "scopes") FROM stdin;
bd3051ed-81ff-4787-9b53-35f01d728f29	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 11:53:19.54823+00	2026-06-12 22:13:59.251929+00	\N	aal1	\N	2026-06-12 22:13:59.251811	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36	103.138.202.212	\N	\N	\N	\N	\N
2ec18d37-f7f9-4c50-aded-7f41346dbcf8	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 22:35:36.273602+00	2026-06-12 22:35:36.273602+00	\N	aal1	\N	\N	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36	103.138.202.214	\N	\N	\N	\N	\N
\.


--
-- Data for Name: mfa_amr_claims; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."mfa_amr_claims" ("session_id", "created_at", "updated_at", "authentication_method", "id") FROM stdin;
bd3051ed-81ff-4787-9b53-35f01d728f29	2026-06-09 11:53:19.56713+00	2026-06-09 11:53:19.56713+00	password	1c8f9679-5a3f-4188-a719-7def77a64836
2ec18d37-f7f9-4c50-aded-7f41346dbcf8	2026-06-12 22:35:36.309536+00	2026-06-12 22:35:36.309536+00	password	6d1de6f0-d2e1-4cc5-8dd0-46f89c84d623
\.


--
-- Data for Name: mfa_factors; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."mfa_factors" ("id", "user_id", "friendly_name", "factor_type", "status", "created_at", "updated_at", "secret", "phone", "last_challenged_at", "web_authn_credential", "web_authn_aaguid", "last_webauthn_challenge_data") FROM stdin;
\.


--
-- Data for Name: mfa_challenges; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."mfa_challenges" ("id", "factor_id", "created_at", "verified_at", "ip_address", "otp_code", "web_authn_session_data") FROM stdin;
\.


--
-- Data for Name: oauth_authorizations; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."oauth_authorizations" ("id", "authorization_id", "client_id", "user_id", "redirect_uri", "scope", "state", "resource", "code_challenge", "code_challenge_method", "response_type", "status", "authorization_code", "created_at", "expires_at", "approved_at", "nonce") FROM stdin;
\.


--
-- Data for Name: oauth_client_states; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."oauth_client_states" ("id", "provider_type", "code_verifier", "created_at") FROM stdin;
\.


--
-- Data for Name: oauth_consents; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."oauth_consents" ("id", "user_id", "client_id", "scopes", "granted_at", "revoked_at") FROM stdin;
\.


--
-- Data for Name: one_time_tokens; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."one_time_tokens" ("id", "user_id", "token_type", "token_hash", "relates_to", "created_at", "updated_at") FROM stdin;
\.


--
-- Data for Name: refresh_tokens; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."refresh_tokens" ("instance_id", "id", "token", "user_id", "revoked", "created_at", "updated_at", "parent", "session_id") FROM stdin;
00000000-0000-0000-0000-000000000000	14	wkluypyh7hdx	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-09 11:53:19.558037+00	2026-06-09 12:51:39.426529+00	\N	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	15	ib47nvpwrirz	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-09 12:51:39.444285+00	2026-06-09 13:50:01.57157+00	wkluypyh7hdx	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	16	zlw7ed5azfqx	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-09 13:50:01.586763+00	2026-06-09 14:49:43.918215+00	ib47nvpwrirz	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	17	dw2n6gnchn6n	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-09 14:49:43.930157+00	2026-06-09 15:50:42.210037+00	zlw7ed5azfqx	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	18	dc5h4zb65wpi	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-09 15:50:42.218416+00	2026-06-09 16:49:10.151309+00	dw2n6gnchn6n	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	19	nkztot2ba2tq	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-09 16:49:10.155601+00	2026-06-09 17:53:09.078769+00	dc5h4zb65wpi	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	20	dyyqrzavspi5	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-09 17:53:09.087661+00	2026-06-09 18:55:19.809842+00	nkztot2ba2tq	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	21	lqqmnvakajmy	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-09 18:55:19.825396+00	2026-06-09 19:55:00.922752+00	dyyqrzavspi5	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	22	x477h2e6aqlj	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-09 19:55:00.930096+00	2026-06-10 03:23:15.056995+00	lqqmnvakajmy	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	23	mk6j2induags	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-10 03:23:15.075627+00	2026-06-10 04:22:30.219249+00	x477h2e6aqlj	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	24	nx7akj4eu22w	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-10 04:22:30.230786+00	2026-06-11 04:48:04.526765+00	mk6j2induags	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	25	6rg6h3cbqfgv	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-11 04:48:04.548576+00	2026-06-11 05:46:27.162253+00	nx7akj4eu22w	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	26	lk7wt2r6vzxo	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-11 05:46:27.176722+00	2026-06-12 05:07:36.980865+00	6rg6h3cbqfgv	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	27	ub7f27e5ztrr	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-12 05:07:36.997229+00	2026-06-12 16:57:27.917518+00	lk7wt2r6vzxo	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	28	3tijhofnsnyy	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-12 16:57:27.930714+00	2026-06-12 17:59:53.081683+00	ub7f27e5ztrr	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	29	o3pu34us5hnx	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-12 17:59:53.09738+00	2026-06-12 19:05:26.812582+00	3tijhofnsnyy	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	30	wjz4474sqbxz	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-12 19:05:26.82591+00	2026-06-12 20:07:40.301956+00	o3pu34us5hnx	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	31	fkacyrufbp5k	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-12 20:07:40.311445+00	2026-06-12 21:06:09.44899+00	wjz4474sqbxz	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	32	me5mvbadfam4	6d459eb2-989d-43ee-9f1d-8f283a9faa94	t	2026-06-12 21:06:09.473383+00	2026-06-12 22:13:59.211374+00	fkacyrufbp5k	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	33	2jkxld2t5dai	6d459eb2-989d-43ee-9f1d-8f283a9faa94	f	2026-06-12 22:13:59.228582+00	2026-06-12 22:13:59.228582+00	me5mvbadfam4	bd3051ed-81ff-4787-9b53-35f01d728f29
00000000-0000-0000-0000-000000000000	34	swaes36xumpp	6d459eb2-989d-43ee-9f1d-8f283a9faa94	f	2026-06-12 22:35:36.291876+00	2026-06-12 22:35:36.291876+00	\N	2ec18d37-f7f9-4c50-aded-7f41346dbcf8
\.


--
-- Data for Name: sso_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."sso_providers" ("id", "resource_id", "created_at", "updated_at", "disabled") FROM stdin;
\.


--
-- Data for Name: saml_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."saml_providers" ("id", "sso_provider_id", "entity_id", "metadata_xml", "metadata_url", "attribute_mapping", "created_at", "updated_at", "name_id_format") FROM stdin;
\.


--
-- Data for Name: saml_relay_states; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."saml_relay_states" ("id", "sso_provider_id", "request_id", "for_email", "redirect_to", "created_at", "updated_at", "flow_state_id") FROM stdin;
\.


--
-- Data for Name: sso_domains; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."sso_domains" ("id", "sso_provider_id", "domain", "created_at", "updated_at") FROM stdin;
\.


--
-- Data for Name: webauthn_challenges; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."webauthn_challenges" ("id", "user_id", "challenge_type", "session_data", "created_at", "expires_at") FROM stdin;
\.


--
-- Data for Name: webauthn_credentials; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."webauthn_credentials" ("id", "user_id", "credential_id", "public_key", "attestation_type", "aaguid", "sign_count", "transports", "backup_eligible", "backed_up", "friendly_name", "created_at", "updated_at", "last_used_at") FROM stdin;
\.


--
-- Name: refresh_tokens_id_seq; Type: SEQUENCE SET; Schema: auth; Owner: supabase_auth_admin
--

SELECT pg_catalog.setval('"auth"."refresh_tokens_id_seq"', 34, true);


--
-- PostgreSQL database dump complete
--

-- \unrestrict 9ZdedA8I2YzbqYA77YBU9xaM1kWsw6gIOZHmT9G5uNfIiQtLVRvVLPsS3vRaRpf

RESET ALL;
