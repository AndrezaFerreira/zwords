# zwords-transcript (legendas do YouTube para a aba Vídeo)

Um site não consegue ler as legendas do YouTube diretamente: o YouTube bloqueia
pedidos vindos de outros sites. Este pequeno serviço gratuito (Cloudflare Worker)
busca a legenda do lado do servidor e entrega ao ZWords.

## Publicar pelo painel da Cloudflare (sem instalar nada)

1. Entre em https://dash.cloudflare.com com a mesma conta do `zwords-api`.
2. **Workers & Pages** › **Create** › **Create Worker** (ou "Start with Hello World").
3. Em **Worker name**, escreva exatamente: `zwords-transcript` › **Deploy**.
4. Clique em **Edit code**, apague o conteúdo, cole todo o arquivo `worker.js` desta pasta
   e clique em **Deploy**.
5. Teste no navegador:
   `https://zwords-transcript.zwords-api.workers.dev/transcript?v=dQw4w9WgXcQ`
   Deve aparecer um texto começando com `{"id":"dQw4w9WgXcQ","lang":"en",...`.

Pronto: a aba Vídeo do ZWords já usa esse endereço.

## Publicar pela linha de comando (alternativa)

```bash
npm install -g wrangler
wrangler login
wrangler deploy tools/transcript-worker/worker.js --name zwords-transcript --compatibility-date 2026-11-01
```

## Limites

- Plano gratuito da Cloudflare: 100 mil pedidos por dia (cada vídeo fica 1 dia em cache).
- O YouTube às vezes recusa pedidos vindos de servidores ou muda o formato interno;
  nesse caso o ZWords avisa e oferece legendar pelo microfone.
- Se o endereço do worker for diferente, ajuste `TRANSCRIPT_API` em `listen.js`.
