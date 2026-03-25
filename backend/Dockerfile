FROM node:20-alpine

WORKDIR /app

# copy package files first for better layer caching
COPY package*.json ./
RUN npm install --omit=dev

# copy source
COPY src/ ./src/

EXPOSE 3000

CMD ["node", "src/index.js"]
